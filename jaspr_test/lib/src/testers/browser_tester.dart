import 'dart:async';
import 'dart:html' as html;

import 'package:domino/browser.dart' as domino;
import 'package:jaspr/browser.dart';

import '../../jaspr_test.dart';

class BrowserTester {
  BrowserTester._(this.binding, this._id);

  final TestBrowserComponentsBinding binding;
  final String _id;

  static BrowserTester setUp({
    String id = 'app',
    String location = '/',
    Map<String, String>? initialStateData,
    Map<String, String> Function(String url)? onFetchState,
  }) {
    if (initialStateData != null) {
      for (var key in initialStateData.keys) {
        html.document.body!.attributes['data-state-$key'] = initialStateData[key]!;
      }
    }

    if (!html.document.body!.children.any((e) => e.id == id)) {
      html.document.body!.append(html.document.createElement('div')..id = id);
    }

    if (html.window.location.pathname != location) {
      html.window.history.replaceState(null, 'Test', location);
    }

    var binding = TestBrowserComponentsBinding(onFetchState);
    return BrowserTester._(binding, id);
  }

  static void tearDown() {}

  Future<void> pumpComponent(Component component) {
    binding.attachRootComponent(component, to: _id);
    return binding.firstBuild;
  }

  Future<void> navigate(Function(RouterState) navigate, {bool pump = true}) async {
    RouterState? router;
    findRouter(Element element) {
      if (element is StatefulElement && element.state is RouterState) {
        router = element.state as RouterState;
      } else {
        element.visitChildren(findRouter);
      }
    }

    binding.rootElement!.visitChildren(findRouter);
    if (router != null) {
      navigate(router!);
      if (pump) {
        await pumpEventQueue();
      }
    }
  }

  Future<void> click(Finder finder, {bool pump = true}) async {
    dispatchEvent(finder, 'click', null);
    if (pump) {
      await pumpEventQueue();
    }
  }

  void dispatchEvent(Finder finder, String event, dynamic data) {
    var element = _findDomElement(finder);

    var source = element.source as html.Element;
    source.dispatchEvent(html.MouseEvent('click'));
  }

  DomElement _findDomElement(Finder finder) {
    var elements = finder.evaluate();

    if (elements.isEmpty) {
      throw 'The finder "$finder" could not find any matching components.';
    }
    if (elements.length > 1) {
      throw 'The finder "$finder" ambiguously found multiple matching components.';
    }

    var element = elements.single;

    if (element is DomElement) {
      return element;
    }

    DomElement? _foundElement;

    void _findFirstDomElement(Element e) {
      if (e is DomElement) {
        _foundElement = e;
        return;
      }
      e.visitChildren(_findFirstDomElement);
    }

    _findFirstDomElement(element);

    if (_foundElement == null) {
      throw 'The finder "$finder" could not find a dom element.';
    }

    return _foundElement!;
  }
}

class TestBrowserComponentsBinding extends BrowserComponentsBinding {
  TestBrowserComponentsBinding(this._onFetchState);

  Completer? _rootViewCompleter;

  @override
  Future<void> get firstBuild => _rootViewCompleter!.future;

  @override
  void attachRootComponent(Component app, {required String to}) {
    _rootViewCompleter = Completer();
    super.attachRootComponent(app, to: to);
  }

  @override
  Future<void> didAttachRootElement(BuildScheduler element, {required String to}) async {
    await super.firstBuild;
    element.view = domino.registerView(
      root: html.document.getElementById(to)!,
      builderFn: element.render,
    );
    _rootViewCompleter!.complete();
  }

  final Map<String, String> Function(String url)? _onFetchState;

  @override
  Future<Map<String, String>> fetchState(String url) async {
    return _onFetchState?.call(url) ?? {};
  }
}
