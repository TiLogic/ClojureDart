import 'dart:io';
import 'dart:isolate';
import 'dart:developer' as dev;
import 'dart:collection';
import 'package:vm_service/vm_service_io.dart' as vms;
import 'package:vm_service/utils.dart' as vmutils;

import 'cljd.dart';
import 'evalexpr.dart' as evalexpr;

Future<bool> reload() async {
  final serverUri = (await dev.Service.getInfo()).serverUri;
  final wsUri = vmutils.convertToWebSocketUrl(serviceProtocolUrl: serverUri).toString();
  final service = await vms.vmServiceConnectUri(wsUri);
  final res = await service.reloadSources(dev.Service.getIsolateID(Isolate.current));
  return res.success;
}

Future eval(x) async {
  // because of side effects on namespaces, x must be emitted before its parent namespace
  final evalsb = StringBuffer();
  emit(x, {}, evalsb, "return ");

  // TODO reemit all dirty nses
  {
    final out = File("lib/" + ns.libname).openWrite();
    try {
      ns.emit(out);
      out.write("Future cljd__eval() async {\n");
      out.write(evalsb);
      out.write("}\n\n");
    } finally {
      await out.close();
    }
  }

  final out = File("lib/evalexpr.dart").openWrite();
  try {
    out.write("import '${ns.libname}' as ns;\n");
    for(var i = 0; i < NamespaceLib.dirtyDefs.length; i++) {
      out.write("import '${NamespaceLib.dirtyDefs[i][0].libname}' as ns_$i;\n");
    }

    out.write("\nFuture exec() async {\n");
    for(var i = 0; i < NamespaceLib.dirtyDefs.length; i++) {
      out.write("ns_$i.cljd__redefs__$i();\n");
    }
    out.write("return ns.cljd__eval();\n}\n");
  } finally {
    NamespaceLib.dirtyDefs.clear();
    await out.close();
  }
  if (!await reload()) {
//    await File("lib/evalexpr.dart").writeAsString("Future exec() => null;\n");
//    await reload(); // TODO throw or msg on false
  }
  return evalexpr.exec();
}

// (require 'foo.bar)
// -> is foo.bar loaded? -> ok
// -> is there a foo/bar.dart file newer than $CLJSRC/foo/bar.clj ? -> add import to current lib
// -> starts evaluating $CLJSRC/foo/bar.clj form by form, produce foo/bar.dart file and then add import to current lib

// (import 'dart:io.Stdout)
// -> import 'dart.io' show Stdout;

/// Half namespace, half lib
class NamespaceLib {
  static final _allNses = Map<Symbol, NamespaceLib>();
  static final dirtyDefs = [];
  final String _name;
  String get libname => _name.replaceAllMapped(RegExp("[.-]"), (m) => m[0] == "." ? "/" : "_") + ".dart";
  /// user-visible aliases, alias -> NamespaceLib
  final _aliases = Map<String, NamespaceLib>();
  /// package to dart alias
  final _mappings = Map<Symbol, dynamic>.from({
      Symbol(null, "to-ns"): "toNs"
  });
  // final _imports = Map(<String, String>)();

  factory NamespaceLib(name) {
    final sym=Symbol(null, name);
    final ns = _allNses[sym] ?? NamespaceLib._new(name);
    _allNses[sym]=ns;
    return ns;
  }

  NamespaceLib._new(this._name) {
    _allNses[Symbol(null, _name)]=this;
  }

  final _flds = Map<Symbol, String>();
  final _fns = Map<Symbol, String>();
  void def(Symbol name, String init) {
    _fns.remove(name);
    if (_flds.containsKey(name)) {
      dirtyDefs.add([this, name]);
    }
    _flds[name] = init;
  }
  void defn(Symbol name, String decl) {
    _flds.remove(name);
    dirtyDefs.removeWhere((pair) => pair[0] == this && pair[1] == name);
    _fns[name] = decl;
  }
  void emit(StringSink out) {
    // TODO remove these two lines:
    out.write("import 'dart:io';\n");
    out.write("import 'compiler.dart';\n");
    out.write("import 'cljd.dart';\n\n");

    _aliases.forEach((alias, ns) {
      out.write("import ${ns.libname} as $alias;\n");
    });
    for(var decl in _fns.values) {
      out..write(decl)..write("\n");
    }
    for(var init in _flds.values) {
      out..write("var ")..write(init)..write("\n");
    }
    for(var i = 0; i < dirtyDefs.length; i++) {
      if (dirtyDefs[i][0] != this) continue;
      out.write("cljd__redefs__$i() {\n");
      out.write(_flds[dirtyDefs[i][1]]);
      out.write("}\n\n");
    }
  }
  resolve(Symbol x) {
    if (x.namespace == null) return _mappings[x];
    if (_aliases[x.namespace] != null) {
      return "${x.namespace}.${x.name}";
    }
    return null;
  }
}

var ns = NamespaceLib("user");
toNs(String s) {
  ns = NamespaceLib(s);
  return ns;
}

const DOT = Symbol(null, ".");
const NEW = Symbol(null, "new");
const FN = Symbol(null, "fn");
const LET = Symbol(null, "let");
const DEF = Symbol(null, "def");
const DO = Symbol(null, "do");
const IF = Symbol(null, "if");
const LOOP = Symbol(null, "loop");
const RECUR = Symbol(null, "recur");
const AMPERSAND = Symbol(null, "&");
const QUOTE = Symbol(null, "quote");

dynamic macroexpand1(dynamic expr) {
  if ((expr is List) && (expr.length > 0)) {
    final first = expr[0];
    if (first is Symbol) {
      final name = first.name;
      if (name.endsWith(".") && name != ".") {
        return List()..add(NEW)..add(Symbol(null, name.substring(0,name.length-1)))..addAll(expr.getRange(1, expr.length));
      }
      if (name.startsWith(".") && name != ".") {
        return List()..add(DOT)..add(expr[1])..add(Symbol(null, name.substring(1)))..addAll(expr.getRange(2, expr.length));
      }
      if (first == DO) {
        return List()..add(LET)..add(PersistentVector.empty())..addAll(expr.getRange(1, expr.length));
      }
    }
    return expr;
  }
  return expr;
}

dynamic macroexpand(dynamic expr) {
  var prev;
  do {
    prev = expr;
    expr = macroexpand1(expr);
  } while (prev != expr);
  return expr;
}

void emitParams(Iterable params, StringSink out) {
  out.write("(");
  var comma = false;
  params.forEach((param) {
      if (comma) out.write(",");
      out.write(param);
      comma=true;
  });
  out.write(")");
}

void emitNew(List expr, env, StringSink out, String locus) {
  final sb = StringBuffer(locus);
  emitExpr(expr[1], env, sb);
  emitArgs(expr.getRange(2, expr.length), env, out, sb.toString());
}

/// Takes a Clojure expression and returns an atomic expression usable
/// as a Dart expression, possibly emitting supporting statements in the process.
liftExpr(expr, env, StringSink out, {Symbol name, nameEnv, force=false, isQuoted=false}) {
  if (isQuoted) return expr;
  final atom = isAtomic(expr);
  if (atom && name == null && !force)
    return expr;
  final varname = name != null ? DartExpr.munge(name, nameEnv ?? env) : DartExpr.tmp();
  if (atom) {
    emit(expr, env, out, "var $varname=", isQuoted: isQuoted);
  } else {
    out.write("var $varname;\n");
    emit(expr, env, out, "$varname=", isQuoted: isQuoted);
  }
  return varname;
}

void emitDot(List expr, env, StringSink out, String locus) {
  final match = RegExp(r"^(-)?(.*)").matchAsPrefix(expr[2].name);
  final sb = StringBuffer(locus);
  emitExpr(liftExpr(expr[1], env, out), env, sb);
  sb.write(".${match.group(2)}");
  if (match.group(1) == null) {
    emitArgs(expr.getRange(3, expr.length), env, out, sb.toString());
  } else {
    out.write(sb..write(";\n"));
  }
}

assoc(m, k, v) {
  final m1 = Map.of(m as Map);
  m1[k]=v;
  return m1;
}
lookup(m, k, [v]) {
  return m.containsKey(k) ? m[k] : v;
}

bool isVariadic(List params) {
  return params.contains(AMPERSAND);
}

void emitBodies(List bodies, env, StringSink out) {
  bodies.sort((a, b) => a.first.length.compareTo(b.first.length));
  var isAlsoVariadic = isVariadic(bodies.last.first);
  var smallestArity = bodies.length == 1 && isAlsoVariadic ? bodies.first.first.length - 2 : bodies.first.first.length;
  var biggestArity = bodies.last.first.length;
  out.write("(");
  List paramsAlias = [];
  for (var i = 0; i < (isAlsoVariadic ? 8 :  biggestArity) ; i++) {
    final temp = DartExpr.tmp();
    paramsAlias.add(temp);
    if (i > 0) out.write(",");
    if (i == smallestArity) out.write("[");
    out.write("$temp");
    if (i >=  smallestArity) out.write("=MISSING_ARG");
  }
  if (bodies.length > 1 || isAlsoVariadic) out.write(']');
  out.write(") {\n");
  for (var i = 0; i < bodies.length - 1; i++) {
    var params = bodies[i][0];
    var bodyenv = env;
    var loopBindings = [];
    out.write("if (${paramsAlias[params.length]} == MISSING_ARG) {\n");
    for(var i = 0; i < params.length; i++) {
      final varname = liftExpr(paramsAlias[i], env, out, name: params[i], nameEnv: bodyenv);
      loopBindings.add(varname);
      bodyenv = assoc(bodyenv, params[i], varname);
    }
    bodyenv = assoc(bodyenv, LOOP_BINDINGS, loopBindings);
    out.write("do {\n");
    emitBody(bodies[i].skip(1).toList(), bodyenv, out, "return ");
    out.write("break;\n} while(true);\n");
    out.write("}\n");
  }
  var params = bodies.last.first;
  var bodyenv = env;
  var loopBindings = [];
  for (var i = 0; i < params.length; i++) {
    if (params[i] == AMPERSAND) {
      final varname = liftExpr(DartExpr("[${paramsAlias.skip(i).toList().join(', ')}].takeWhile((e) => e != MISSING_ARG).toList()"), env, out, name: params[i+1], nameEnv: bodyenv);
      loopBindings.add(varname);
      bodyenv = assoc(bodyenv, params[i+1], varname);
      break;
    }
    final varname = DartExpr.munge(params[i], bodyenv);
    loopBindings.add(varname);
    out.write("var $varname=${paramsAlias[i]};\n");
    bodyenv = assoc(bodyenv, params[i], varname);
  }
  bodyenv = assoc(bodyenv, LOOP_BINDINGS, loopBindings);
  out.write("do {\n");
  emitBody(bodies.last.skip(1).toList(), bodyenv, out, "return ");
  out.write("break;\n} while(true);\n");
  out.write("}");
}

List extractBodies(List expr) {
  bool namedFn = expr[1] is Symbol;
  final offset = namedFn ? 2 : 1;
  return expr[offset] is PersistentVector ? [expr.skip(offset).toList()] : expr.skip(offset).toList();
}

void emitFn(List expr, env, StringSink out, String locus) {
  bool namedFn = expr[1] is Symbol;
  var bodies = extractBodies(expr);
  if (namedFn) {
    final fnname = DartExpr.munge(expr[1], env);
    env = assoc(env, expr[1], fnname);
    out.write(fnname);
    emitBodies(bodies, env, out);
    out.write("\n$locus$fnname;\n");
  } else {
    out.write(locus);
    emitBodies(bodies, env, out);
    out.write(";\n");
  }
}

void emitTopFn(Symbol name, List expr, env, StringSink out) {
  bool namedFn = expr[1] is Symbol;
  // @TODO : on n'est pas clair sur la nature du name (dixit @cgrand)
  if (namedFn) {
    env = assoc(env, expr[1], name.toString());
  }
  emitSymbol(name, env, out);
  emitBodies(extractBodies(expr), env, out);
  out.write("\n");
}

void emitIf(List expr, env, StringSink out, String locus) {
  final test = liftExpr(expr[1], env, out);
  out.write("if ($test) {\n");
  emit(expr[2], env, out, locus);
  out.write("}else{\n");
  emit((expr.length == 4) ? expr[3] : null, env, out, locus);
  out.write("}\n");
  return;
}

void emitBody(List exprs, env, StringSink out, String locus) {
  for (var i = 0; i < exprs.length-1; i++) {
    emit(exprs[i], env, out, ""); // pure effect
  }
  emit(exprs.last, env, out, locus);
}

void emitLet(List expr, env, StringSink out, String locus) {
  final bindings = expr[1];
  for (var i = 0; i < bindings.length; i += 2) {
    final sym = bindings[i];
    final varname = liftExpr(bindings[i+1], env, out, name: sym);
    env = assoc(env, sym, varname);
  }
  emitBody(expr.skip(2).toList(), env, out, locus);
}

const LOOP_BINDINGS = Keyword("cljd.compiler", "loop-bindings");

void emitLoop(List expr, env, StringSink out, String locus) {
  final bindings = expr[1];
  var loopBindings = [];
  for (var i = 0; i < bindings.length; i += 2) {
    final sym = bindings[i];
    final varname = liftExpr(bindings[i+1], env, out, name: sym);
    loopBindings.add(varname);
    env = assoc(env, sym, varname);
  }
  out.write("do {\n");
  emitBody(expr.skip(2).toList(), assoc(env, LOOP_BINDINGS, loopBindings), out, locus);
  out.write("break;\n} while(true);\n");
}

void emitRecur(List expr, env, StringSink out, String locus) {
  var args=List();
  for(var i = 1; i < expr.length; i++) {
    args.add(liftExpr(expr[i], env, out, force: true));
  }
  var loopBindings = lookup(env, LOOP_BINDINGS);
  // DON'T MERGE the for above with the one below:
  // evaluation of all exprs MUST occur before reassignment
  for (var i = 0; i < args.length; i++) {
    emit(args[i], env, out, "${loopBindings[i]}=");
  }
  out.write("continue;\n");
}

void emitSymbol(Symbol sym, env, StringSink out, {bool isQuoted=false}) {
  if (isQuoted) {
    out.write("Symbol(null, \"${sym.name}\")");
    return;
  }
  out.write(lookup(env, sym) ?? ns.resolve(sym) ?? sym.name);
}

void emitStr(String s, StringSink out) {
  out..write('"')
    ..write(s.replaceAllMapped(RegExp("([\x00-\x1f])|[\$\"]"), (m) {
      if (m.group(1) == null) return "\\${m.group(0)}";
      switch(m.group(1)) {
        case '\b': return "\\b";
        case '\n': return "\\n";
        case '\r': return "\\r";
        case '\t': return "\\t";
        case '\f': return "\\f";
        case '\v': return "\\v";
      }
      return "\\x${m.group(1).codeUnitAt(0).toRadixString(16).padLeft(2,'0')}";
    }))
    ..write('"');
}

class DartExpr {
  static var _counter=0;
  String _expr;
  DartExpr(this._expr);
  DartExpr.tmp() { _expr="_${++_counter}"; }
  DartExpr.munge(Symbol v, env) {
    _expr = lookup(env, v) == null ? v.name : "${v.name}__${++_counter}";
  }
  toString() => _expr;
}

bool isAtomic(x) {
  return x == null || x is Symbol || x is Keyword || x is String || x is bool || x is num || x is DartExpr;
}

void emitFnCall(List expr, env, StringSink out, String locus) {
  final sb = StringBuffer(locus);
  emitExpr(liftExpr(expr[0], env, out), env, sb);
  emitArgs(expr.getRange(1, expr.length), env, out, sb.toString());
}

void emitArgs(Iterable expr, env, StringSink out, String locus) {
  var named = false;
  var keypos = true;
  final args = expr.map((x) {
    keypos = !keypos;
    if (x == AMPERSAND) {
      named = true;
      keypos = false;
      return x;
    }
    if (named && keypos)
      return x;
    return liftExpr(x, env, out);
  }).toList();
  out.write("$locus(");
  var comma=false;
  named = false;
  args.forEach((arg) {
    if (arg == AMPERSAND) {
      named=true;
      keypos=false;
      return;
    }
    if (comma) out.write(", ");
    comma=true;
    keypos = !keypos;
    if (named && keypos) {
      out.write("${arg.name}: ");
      comma = false;
      return;
    }
    emitExpr(arg, env, out);
  });
  out.write(");\n");
}

void emitExpr(dynamic expr, env, StringSink out, {bool isQuoted=false}) {
  if (expr is Iterable) {
    emitCollection(expr, env, out, "", isQuoted: isQuoted);
  } else if (expr is Symbol) {
    emitSymbol(expr, env, out, isQuoted: isQuoted);
  } else if (expr is String) {
    emitStr(expr, out);
  } else {
    out.write(expr.toString());
  }
}

void emitDef(dynamic expr, env, StringSink out, String locus) {
  final sym = expr[1];
  final value = macroexpand(expr[2]);
  final sb = StringBuffer();
  if (value is List && value[0] == FN) {
    emitTopFn(sym, value, env, sb);
    ns.defn(sym, sb.toString());
  } else {
    emitSymbol(sym, env, sb);
    sb.write("=");
    if (isAtomic(value)) {
      emitExpr(value, env, sb);
    } else {
      sb.write("(){\n");
      emit(value, env, sb, "return ");
      sb.write("}()");
    }
    sb.write(";\n");
    ns.def(sym, sb.toString());
  }
  emit(expr[1], env, out, locus);
}

void emitCollection(dynamic expr, env, StringSink out, String locus, {bool isQuoted=false}) {
  final sb = StringBuffer("${locus}");
  if (expr is PersistentVector) {
    sb.write("PersistentVector.empty()");
  } else if (expr is List) {
    sb.write("List()");
  } else if (expr is Set) {
    sb.write("Set()");
  }
  expr.forEach((e) {
      sb.write("..add(");
      emitExpr(liftExpr(e, env, out, isQuoted: isQuoted), env, sb, isQuoted: isQuoted);
      sb.write(")");
  });
  out.write(sb.toString());
}

void emit(dynamic expr, env, StringSink out, String locus, {bool isQuoted=false}) {
  expr=macroexpand(expr);
  // PersistentVector are List as of Sat Nov 21 16:02:34 2020 so we need to double check when emitting PersistentVector
  if (!isQuoted && expr is List && expr is! PersistentVector) {
    if (expr.first == NEW) {
      emitNew(expr, env, out, locus);
      return;
    }
    if (expr.first == DOT) {
      emitDot(expr, env, out, locus);
      return;
    }
    if (expr.first == FN) {
      emitFn(expr, env, out, locus);
      return;
    }
    if (expr.first == LET) {
      emitLet(expr, env, out, locus);
      return;
    }
    if (expr.first == DEF) {
      emitDef(expr, env, out, locus);
      return;
    }
    if (expr.first == IF) {
      emitIf(expr, env, out, locus);
      return;
    }
    if (expr.first == LOOP) {
      emitLoop(expr, env, out, locus);
      return;
    }
    if (expr.first == RECUR) {
      emitRecur(expr, env, out, locus);
      return;
    }
    if (expr.first == QUOTE) {
      emit(expr[1], env, out, locus, isQuoted: true);
      return;
    }
    emitFnCall(expr, env, out, locus);
    return;
  }
  if (expr is Iterable) {
    emitCollection(expr, env, out, locus, isQuoted: isQuoted);
    out.write(";\n");
    return;
  }
  out.write(locus);
  emitExpr(expr, env, out, isQuoted: isQuoted);
  out.write(";\n");
}