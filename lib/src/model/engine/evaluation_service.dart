import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dartchess/dartchess.dart' hide File;
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show showAdaptiveDialog;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:http/http.dart';
import 'package:lichess_mobile/src/constants.dart';
import 'package:lichess_mobile/src/model/common/chess.dart';
import 'package:lichess_mobile/src/model/common/eval.dart';
import 'package:lichess_mobile/src/model/common/preloaded_data.dart';
import 'package:lichess_mobile/src/model/common/uci.dart';
import 'package:lichess_mobile/src/model/engine/engine.dart';
import 'package:lichess_mobile/src/model/engine/evaluation_preferences.dart';
import 'package:lichess_mobile/src/model/engine/work.dart';
import 'package:lichess_mobile/src/navigation.dart';
import 'package:lichess_mobile/src/network/connectivity.dart';
import 'package:lichess_mobile/src/network/http.dart';
import 'package:lichess_mobile/src/widgets/yes_no_dialog.dart';
import 'package:multistockfish/multistockfish.dart';
import 'package:path_provider/path_provider.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:stream_transform/stream_transform.dart';

part 'evaluation_service.freezed.dart';
part 'evaluation_service.g.dart';

const kEngineEvalEmissionThrottleDelay = Duration(milliseconds: 200);

final maxEngineCores = max(Platform.numberOfProcessors - 1, 1);
final defaultEngineCores = min((Platform.numberOfProcessors / 2).ceil(), maxEngineCores);

const engineSupportedVariants = {Variant.standard, Variant.chess960, Variant.fromPosition};

@Riverpod(keepAlive: true)
EvaluationService evaluationService(Ref ref) {
  final maxMemory = ref.read(preloadedDataProvider).requireValue.engineMaxMemoryInMb;
  final service = EvaluationService(ref, maxMemory: maxMemory);

  ref.onDispose(() {
    service._dispose();
  });

  return service;
}

/// A service to evaluate chess positions using an engine.
class EvaluationService {
  EvaluationService(Ref ref, {required this.maxMemory}) : _ref = ref;

  final Ref _ref;
  final int maxMemory;

  Engine? _engine;

  EvaluationContext? _context;

  EvaluationOptions options = EvaluationOptions(
    evaluationFunction: EvaluationFunctionPref.hce,
    multiPv: 1,
    cores: defaultEngineCores,
    searchTime: const Duration(seconds: 10),
  );

  static const _defaultState = (engineName: 'Stockfish', state: EngineState.initial, eval: null);

  final ValueNotifier<EngineEvaluationState> _state = ValueNotifier(_defaultState);
  ValueListenable<EngineEvaluationState> get state => _state;

  Future<Engine> _engineFactory(EvaluationFunctionPref pref) async {
    switch (pref) {
      case EvaluationFunctionPref.nnue:
        try {
          final nnueFiles = await _ref.read(stockfishNNUEFilesProvider.future);
          return StockfishEngine(
            StockfishFlavor.nnue,
            bigNetPath: nnueFiles.bigNetPath,
            smallNetPath: nnueFiles.smallNetPath,
          );
        } catch (e, st) {
          debugPrint('Failed to load NNUE files: $e\n$st');
          return StockfishEngine(StockfishFlavor.hce);
        }
      case EvaluationFunctionPref.hce:
        return StockfishEngine(StockfishFlavor.hce);
    }
  }

  /// Initialize the engine with the given context and options.
  ///
  /// If the engine is already initialized, it is disposed first.
  ///
  /// If [options] is not provided, the default options are used.
  /// This method must be called before calling [start]. It is the caller's
  /// responsibility to close the engine.
  Future<void> _initEngine(EvaluationContext context, {EvaluationOptions? initOptions}) async {
    await disposeEngine();
    _context = context;
    if (initOptions != null) options = initOptions;
    _engine = await _engineFactory(options.evaluationFunction);
    _engine!.state.addListener(() {
      debugPrint('Engine state: ${_engine?.state.value}');
      if (_engine?.state.value == EngineState.initial ||
          _engine?.state.value == EngineState.disposed) {
        _state.value = _defaultState;
      }
      if (_engine?.state != null) {
        _state.value = (
          engineName: _engine!.name,
          state: _engine!.state.value,
          eval: _state.value.eval,
        );
      }
    });
  }

  /// Ensure the engine is initialized with the given context and options.
  Future<void> ensureEngineInitialized(
    EvaluationContext context, {
    EvaluationOptions? initOptions,
  }) async {
    if (_engine == null ||
        _engine?.isDisposed == true ||
        _context != context ||
        options != initOptions) {
      await _initEngine(context, initOptions: initOptions);
    }
  }

  /// Dispose the engine.
  ///
  /// Returns a future that completes once the engine is disposed.
  /// It is safe to call this method multiple times.
  Future<void> disposeEngine() {
    return _engine?.dispose() ?? Future.value();
  }

  /// Dispose the service.
  void _dispose() {
    disposeEngine();
    _state.dispose();
  }

  /// Start the engine evaluation with the given [path] and [steps].
  ///
  /// Returns a stream of [EvalResult]s. The stream is throttled to emit at most
  /// one value every 200 milliseconds.
  /// For each evaluation in the stream, if [shouldEmit] returns true, the eval
  /// is emitted by the [EngineEvaluation] provider.
  ///
  /// [initEngine] must be called before calling this method.
  Stream<EvalResult>? start(
    UciPath path,
    Iterable<Step> steps, {
    ClientEval? initialPositionEval,

    /// A function that returns true if the evaluation should be emitted by the
    /// [EngineEvaluation] provider.
    required bool Function(Work work) shouldEmit,
  }) {
    final context = _context;
    final engine = _engine;
    if (context == null || engine == null) {
      assert(false, 'Engine not initialized');
      return null;
    }

    if (!engineSupportedVariants.contains(context.variant)) {
      return null;
    }

    // reset eval
    _state.value = (engineName: _state.value.engineName, state: _state.value.state, eval: null);

    final work = Work(
      variant: context.variant,
      threads: options.cores,
      hashSize: maxMemory,
      searchTime: options.searchTime,
      multiPv: options.multiPv,
      path: path,
      initialPosition: context.initialPosition,
      steps: IList(steps),
    );

    // cancel evaluation if we already have an interesting eval
    final cachedEval = work.steps.isEmpty ? initialPositionEval : work.evalCache;
    switch (cachedEval) {
      // if the search time is greater than the current search time, don't evaluate again
      case final LocalEval localEval when localEval.searchTime >= options.searchTime:
      case CloudEval _:
        return null;
      case _:
        break;
    }

    final evalStream = engine
        .start(work)
        .throttle(kEngineEvalEmissionThrottleDelay, trailing: true);

    evalStream.forEach((t) {
      final (work, eval) = t;
      if (shouldEmit(work)) {
        _state.value = (engineName: _state.value.engineName, state: _state.value.state, eval: eval);
      }
    });

    return evalStream;
  }

  void stop() {
    _engine?.stop();
  }
}

typedef EngineEvaluationState = ({String engineName, EngineState state, LocalEval? eval});

/// A provider that holds the state of the engine and the current evaluation.
@riverpod
class EngineEvaluation extends _$EngineEvaluation {
  @override
  EngineEvaluationState build() {
    final listenable = ref.watch(evaluationServiceProvider).state;

    listenable.addListener(_listener);

    ref.onDispose(() {
      listenable.removeListener(_listener);
    });

    return listenable.value;
  }

  void _listener() {
    final newState = ref.read(evaluationServiceProvider).state.value;
    if (state != newState) {
      state = newState;
    }
  }
}

@freezed
class EvaluationContext with _$EvaluationContext {
  const factory EvaluationContext({required Variant variant, required Position initialPosition}) =
      _EvaluationContext;
}

@freezed
class EvaluationOptions with _$EvaluationOptions {
  const factory EvaluationOptions({
    required EvaluationFunctionPref evaluationFunction,
    required int multiPv,
    required int cores,
    required Duration searchTime,
  }) = _EvaluationOptions;
}

/// A function to choose the eval that should be displayed.
Eval? pickBestEval({
  /// The eval from the local engine
  required LocalEval? localEval,

  /// The cached eval which is either a saved eval from the local evaluation or a cloud eval
  required ClientEval? savedEval,

  /// The eval from the server analysis
  required ExternalEval? serverEval,
}) {
  return switch (savedEval) {
    CloudEval() => savedEval,
    LocalEval() => localEval ?? savedEval,
    null => localEval ?? serverEval,
  };
}

/// A function to choose the client eval that should be displayed.
ClientEval? pickBestClientEval({
  /// The eval from the local engine
  required LocalEval? localEval,

  /// The cached eval which is either a saved eval from the local evaluation or a cloud eval
  required ClientEval? savedEval,
}) {
  final eval =
      pickBestEval(localEval: localEval, savedEval: savedEval, serverEval: null) as ClientEval?;

  return eval;
}

/// A function to choose the best moves that should be displayed.
IList<MoveWithWinningChances>? pickBestMoves({
  /// The best moves from the local engine
  required IList<MoveWithWinningChances>? localBestMoves,

  /// The cached eval which is either a saved eval from the local evaluation or a cloud eval
  required ClientEval? savedEval,
}) {
  return switch (savedEval) {
    CloudEval() => savedEval.bestMoves,
    LocalEval() => localBestMoves ?? savedEval.bestMoves,
    null => localBestMoves,
  };
}

Directory? _appSupportDirectory;
const _nnueDownloadUrl = '$kLichessCDNHost/assets/lifat/nnue/';
typedef NNUEFiles = ({String bigNetPath, String smallNetPath});

/// Fetches and saves locally the Stockfish NNUE files from the server.
@riverpod
Future<NNUEFiles> stockfishNNUEFiles(Ref ref) async {
  _appSupportDirectory ??= await getApplicationSupportDirectory();

  final link = ref.keepAlive();

  final bigNetUrl = Uri.parse('$_nnueDownloadUrl${Stockfish.defaultBigNetFile}');
  final smallNetUrl = Uri.parse('$_nnueDownloadUrl${Stockfish.defaultSmallNetFile}');

  final bigNetFile = File('${_appSupportDirectory!.path}/${Stockfish.defaultBigNetFile}');
  final smallNetFile = File('${_appSupportDirectory!.path}/${Stockfish.defaultSmallNetFile}');

  if (await bigNetFile.exists() && await smallNetFile.exists()) {
    return (bigNetPath: bigNetFile.path, smallNetPath: smallNetFile.path);
  }

  try {
    // delete any existing nnue files before downloading
    final dir = Directory(_appSupportDirectory!.path);
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is File && entity.path.endsWith('.nnue')) {
        debugPrint('Deleting existing nnue ${entity.path}');
        await entity.delete();
      }
    }

    final connectivityResult = await ref.read(connectivityPluginProvider).checkConnectivity();

    bool? downloadAllowed;

    final currentContext = ref.read(currentNavigatorKeyProvider).currentContext;
    if (currentContext == null || !currentContext.mounted) {
      throw StateError('No current context');
    }

    // if only mobile data is available, prompt the user with a confirmation dialog
    if (connectivityResult.contains(ConnectivityResult.mobile) &&
        !connectivityResult.contains(ConnectivityResult.wifi)) {
      downloadAllowed = await showAdaptiveDialog<bool>(
        context: currentContext,
        builder:
            (context) => YesNoDialog(
              title: const Text('Confirm download'),
              content: const Text(
                'You are about to download the Stockfish NNUE files (79MB) using mobile data. Do you want to proceed?\n\nIf you do not download the files, the engine will use the handcrafted evaluation function instead.\n\nYou can also change the preferred evaluation function in the engine settings.',
              ),
              onYes: () {
                return Navigator.of(context).pop(true);
              },
              onNo: () => Navigator.of(context).pop(false),
            ),
      );
    }

    if (downloadAllowed == false) {
      link.close();
      throw Exception('Download not allowed');
    }

    final client = ref.read(defaultClientProvider);

    await Future.wait([
      downloadFile(client, bigNetUrl, bigNetFile),
      downloadFile(client, smallNetUrl, smallNetFile),
    ]);
    return (bigNetPath: bigNetFile.path, smallNetPath: smallNetFile.path);
  } on SocketException catch (_) {
    link.close();
    rethrow;
  } on ClientException catch (_) {
    link.close();
    rethrow;
  }
}
