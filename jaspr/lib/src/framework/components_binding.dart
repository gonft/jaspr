part of framework;

/// Main app binding, controls the root component and global state
abstract class ComponentsBinding {
  /// The currently active uri.
  /// On the server, this is the requested uri. On the client, this is the
  /// currently visited uri in the browser.
  Uri get currentUri;

  static ComponentsBinding? _instance;
  static ComponentsBinding? get instance => _instance;

  ComponentsBinding() {
    _instance = this;
    _owner = BuildOwner();
  }

  late BuildOwner _owner;

  /// Whether the current app is run on the client (in the browser)
  bool get isClient;

  /// Sets [app] as the new root of the component tree and performs an initial build
  void attachRootComponent(Component app, {required String to}) {
    var element = _Root(child: app).createElement();
    element._root = this;

    var syncBuildLock = Future.value();
    _initialBuildQueue.add(syncBuildLock);

    element.mount(null);
    _rootElement = element;

    didAttachRootElement(element, to: to);

    _initialBuildQueue.remove(syncBuildLock);
  }

  @protected
  void didAttachRootElement(BuildScheduler element, {required String to});

  /// The [Element] that is at the root of the hierarchy.
  ///
  /// This is initialized the first time [runApp] is called.
  SingleChildElement? get rootElement => _rootElement;
  SingleChildElement? _rootElement;

  /// Returns the accumulated data from all active [State]s that use the [SyncStateMixin]
  @protected
  Map<String, String> getStateData() {
    var state = <String, String>{};
    for (var key in _globalKeyRegistry.keys) {
      if (key._canSync) {
        var s = key._saveState();
        state[key._id] = s;
      }
    }
    return state;
  }

  /// Must return the serialized state data associated with [id]. On the client this is the
  /// data that is synced from the server.
  @protected
  String? getRawState(String id);

  /// Must update the serialized state data associated with [id]. This is called on the client
  /// when new data is loaded for a [LazyRoute].
  @protected
  void updateRawState(String id, String state);

  bool _isLoadingState = false;
  bool get isLoadingState => _isLoadingState;

  /// Loads state from the server and and notifies elements.
  /// This is called when a [LazyRoute] is loaded.
  Future<void> loadState(String path) async {
    _isLoadingState = true;
    var data = await fetchState(path);
    _isLoadingState = false;

    for (var id in data.keys) {
      updateRawState(id, data[id]!);
    }

    for (var key in _globalKeyRegistry.keys) {
      if (key._canSync && data.containsKey(key._id)) {
        key._notifyState(data[key._id]);
      }
    }
  }

  /// On the client, this should perform a http request to [url] to fetch state data from the server.
  @protected
  Future<Map<String, String>> fetchState(String url);

  final List<Future> _initialBuildQueue = [];

  /// Whether the initial build is currently performed.
  bool get isFirstBuild => _initialBuildQueue.isNotEmpty;

  /// Future that resolves when the initial build is completed.
  Future<void> get firstBuild async {
    while (_initialBuildQueue.isNotEmpty) {
      await _initialBuildQueue.first;
    }
  }

  /// Rebuilds [child] and correctly accounts for any asynchronous operations that can occurr during the initial
  /// build of an app.
  /// Async builds are only allowed for [StatefulComponent]s that use the [PreloadDataMixin] or [DeferRenderMixin].
  void performRebuildOn(Element? child, [void Function()? whenComplete]) {
    var built = performRebuild(child);
    if (built is Future) {
      assert(isFirstBuild, 'Only the first build is allowed to be asynchronous.');
      _initialBuildQueue.add(built);
      built.whenComplete(() {
        _initialBuildQueue.remove(built);
        whenComplete?.call();
      });
    } else {
      whenComplete?.call();
    }
  }

  /// The first build on server and browser is allowed to have asynchronous operations (i.e. preloading data)
  /// However we want the component and element apis to stay synchronous, so subclasses
  /// can override this method to simulate an async build for a child
  @protected
  @mustCallSuper
  FutureOr<void> performRebuild(Element? child) {
    child?.performRebuild();
  }

  final Map<GlobalKey, Element> _globalKeyRegistry = {};

  void _registerGlobalKey(GlobalKey key, Element element) {
    _globalKeyRegistry[key] = element;
  }

  void _unregisterGlobalKey(GlobalKey key, Element element) {
    if (_globalKeyRegistry[key] == element) {
      _globalKeyRegistry.remove(key);
    }
  }
}

/// In difference to Flutter, we have multiple build schedulers instead of one global build owner
/// Particularly each dom element is a build scheduler and manages its subtree of components
mixin BuildScheduler on Element {
  DomView? _view;

  DomView get view => _view!;
  set view(DomView v) {
    _view = v;
  }
}

class _Root extends Component {
  _Root({required this.child});

  final Component child;

  @override
  _RootElement createElement() => _RootElement(this);
}

class _RootElement extends SingleChildElement with BuildScheduler {
  _RootElement(_Root component) : super(component);

  @override
  _Root get component => super.component as _Root;

  @override
  Component build() => component.child;
}

class BuildOwner {
  final List<Element> _dirtyElements = <Element>[];

  Future? _scheduledBuild;

  BuildScheduler? _schedulerContext;

  final _InactiveElements _inactiveElements = _InactiveElements();

  /// Whether [_dirtyElements] need to be sorted again as a result of more
  /// elements becoming dirty during the build.
  ///
  /// This is necessary to preserve the sort order defined by [Element._sort].
  ///
  /// This field is set to null when [performBuild] is not actively rebuilding
  /// the widget tree.
  bool? _dirtyElementsNeedsResorting;

  /// Whether this widget tree is in the build phase.
  ///
  /// Only valid when asserts are enabled.
  bool get debugBuilding => _debugBuilding;
  bool _debugBuilding = false;

  void scheduleBuildFor(Element element) {
    assert(!ComponentsBinding.instance!.isFirstBuild);
    assert(element.dirty, 'scheduleBuildFor() called for a widget that is not marked as dirty.');

    if (element._inDirtyList) {
      _dirtyElementsNeedsResorting = true;
      return;
    }
    _scheduledBuild ??= Future.microtask(performBuild);
    if (_schedulerContext == null || element._scheduler!.depth < _schedulerContext!.depth) {
      _schedulerContext = element._scheduler;
    }

    _dirtyElements.add(element);
    element._inDirtyList = true;
  }

  void performBuild() {
    assert(!ComponentsBinding.instance!.isFirstBuild);

    assert(_schedulerContext != null);
    assert(!_debugBuilding);

    assert(() {
      _debugBuilding = true;
      return true;
    }());

    try {
      _dirtyElements.sort(Element._sort);
      _dirtyElementsNeedsResorting = false;

      int dirtyCount = _dirtyElements.length;
      int index = 0;

      while (index < dirtyCount) {
        final Element element = _dirtyElements[index];
        assert(element._inDirtyList);

        try {
          element.rebuild();
          assert(!element._dirty, 'Build was not finished synchronously on $element');
        } catch (e) {
          // TODO: properly report error
          print("Error on rebuilding component: $e");
        }

        index += 1;
        if (dirtyCount < _dirtyElements.length || _dirtyElementsNeedsResorting!) {
          _dirtyElements.sort(Element._sort);
          _dirtyElementsNeedsResorting = false;
          dirtyCount = _dirtyElements.length;
          while (index > 0 && _dirtyElements[index - 1].dirty) {
            index -= 1;
          }
        }
      }

      assert(() {
        if (_dirtyElements
            .any((Element element) => element._lifecycleState == _ElementLifecycle.active && element.dirty)) {
          throw 'buildScope missed some dirty elements.';
        }
        return true;
      }());
    } finally {
      for (final Element element in _dirtyElements) {
        assert(element._inDirtyList);
        element._inDirtyList = false;
      }
      _dirtyElements.clear();
      _dirtyElementsNeedsResorting = null;

      _schedulerContext!.view.update();
      _schedulerContext = null;

      _inactiveElements._unmountAll();

      _scheduledBuild = null;

      assert(_debugBuilding);
      assert(() {
        _debugBuilding = false;
        return true;
      }());
    }
  }
}
