#!/usr/bin/env dart

import 'dart:io';

import 'package:analyzer/analyzer.dart' as ast;
import 'package:pretty/pretty.dart' as pretty;

main(List<String> args) {
  if (args.length != 1) {
    print('Usage: dart2ast [Dart file]');
    exit(0);
  }

  String path = args.first;
  ast.CompilationUnit compilationUnit = ast.parseDartFile(path);
  Ast2SexpVisitor visitor = new Ast2SexpVisitor();
  print(sexp2Doc(compilationUnit.accept(visitor)).render(120));
}


pretty.Document sexp2Doc(expression) {
  if (expression is String) return pretty.text(expression);
  if ((expression as List).isEmpty) return pretty.text('()');

  Iterable<pretty.Document> docs = (expression as List).map(sexp2Doc);
  pretty.Document result = pretty.text('(') + docs.first;
  pretty.Document children =
      docs.skip(1).fold(pretty.empty,
          (doc0, doc1) => doc0 + pretty.line + doc1);
  result += (children + pretty.text(')')).nest(2);
  return result.group;
}


/// Translate a compilation unit AST to a list of S-expressions.
///
/// An S-expression is an atom (string in this case) or a list of
/// S-expressions.
class Ast2SexpVisitor extends ast.GeneralizingAstVisitor {
  giveup(String why) {
    print('Unsupported syntax: $why.');
    exit(0);
  }

  visit(ast.AstNode node) => node.accept(this);

  visitNode(ast.AstNode node) {
    giveup(node.runtimeType.toString());
  }

  visitCompilationUnit(ast.CompilationUnit node) {
    return node.sortedDirectivesAndDeclarations.reversed.map(visit)
        .toList(growable: false);
  }

  visitFunctionDeclaration(ast.FunctionDeclaration node) {
    if (node.name == null) giveup('unnamed function declaration');

    // ==== Tag and name ====
    String tag;
    String name = node.name.name;
    if (name.contains('_async')) {
      tag = 'Async';
    } else if (name.contains('_syncStar')) {
      tag = 'SyncStar';
    } else {
      tag = 'Sync';
    }

    // ==== Parameter list ====
    ast.FunctionExpression function = node.functionExpression;
    List parameters = function.parameters.parameters.map(visit)
        .toList(growable: false);

    // ==== Local variable list ====
    // Here it is assumed that all variables have been hoisted to the top of
    // the function and declared (but not initialized) in a single statement.
    // There is allowed to be no declaration.
    if (function.body is! ast.BlockFunctionBody) {
      giveup('not a block function');
    }
    ast.Block block = (function.body as ast.BlockFunctionBody).block;
    List locals;
    if (block.statements.isEmpty
        || block.statements.first is! ast.VariableDeclarationStatement) {
      locals = [];
    } else {
      locals = (block.statements.first as ast.VariableDeclarationStatement)
          .variables.variables.map(visit).toList(growable: false);
    }

    bool first = true;
    List body = [];
    for (ast.Statement s in block.statements) {
      // Skip an initial variable declaration statement.
      if (!first || s is! ast.VariableDeclarationStatement) {
        body.add(visit(s));
      }
      first = false;
    }

    return [tag, name, parameters, locals, ['Block', body]];
  }

  visitSimpleFormalParameter(ast.SimpleFormalParameter node) {
    return node.identifier.name;
  }

  visitVariableDeclaration(ast.VariableDeclaration node) {
    return node.name.name;
  }

  // ==== Expressions ====
  visitIntegerLiteral(ast.IntegerLiteral node) {
    return ['Constant', node.value.toString()];
  }

  visitSimpleIdentifier(ast.SimpleIdentifier node) {
    return ['Variable', node.name];
  }

  visitAssignmentExpression(ast.AssignmentExpression node) {
    if (node.leftHandSide is! ast.SimpleIdentifier) {
      giveup('non-simple rhs in assignment');
    }
    return ['Assignment', (node.leftHandSide as ast.SimpleIdentifier).name,
            visit(node.rightHandSide)];
  }

  visitMethodInvocation(ast.MethodInvocation node) {
    if (node.target != null) giveup("method with a receiver");

    // It is not checked that yield and yield* occur as statements.
    String name = node.methodName.name;
    ast.NodeList<ast.Expression> arguments = node.argumentList.arguments;
    String tag;
    if (name == 'await') {
      tag = 'Await';
    } else if (name == 'yield') {
      tag = 'Yield';
    } else if (name == 'yieldStar') {
      tag = 'YieldStar';
    }

    if (tag != null) {
      if (arguments.length != 1) giveup('wrong arity for $name');
      return [tag, visit(arguments.first)];
    } else {
      List arguments = node.argumentList.arguments.map(visit)
          .toList(growable: false);
      return ['Call', name, arguments];
    }
  }

  visitThrowExpression(ast.ThrowExpression node) {
    return ['Throw', visit(node.expression)];
  }

  // ==== Statements ====
  visitBlock(ast.Block node) {
    List body = node.statements.map(visit).toList(growable: false);
    return ['Block', body];
  }

  visitExpressionStatement(ast.ExpressionStatement node) {
    List expression = visit(node.expression);
    if (['Yield', 'YieldStar'].contains(expression.first)) {
      // Yield and YieldStar are statements, not expressions.
      return expression;
    } else {
      return ['Expression', visit(node.expression)];
    }
  }

  visitReturnStatement(ast.ReturnStatement node) {
    // A subexpression is required for return, except for a return from a
    // sync* function, which should have no subexpression.
    return node.expression == null
        ? ['YieldBreak']
        : ['Return', visit(node.expression)];
  }

  visitIfStatement(ast.IfStatement node) {
    if (node.elseStatement == null) giveup('if without an else');
    return ['If', visit(node.condition), visit(node.thenStatement),
            visit(node.elseStatement)];
  }

  visitLabeledStatement(ast.LabeledStatement node) {
    // Loops in the output are always labeled.  If the labeled statement is
    // a loop then the label is attached to the loop.
    if (node.labels.length != 1) giveup('multiple labels');
    String label = node.labels.first.label.name;
    List statement = visit(node.statement);
    if (statement.first == 'While') {
      statement[1] = label;
      return statement;
    } else {
      return ['Label', label, statement];
    }
  }

  visitBreakStatement(ast.BreakStatement node) {
    if (node.label == null) giveup('break without a label');
    return ['Break', node.label.name];
  }

  visitWhileStatement(ast.WhileStatement node) {
    // There is a null placeholder for the statement's label.  It is filled
    // in by the caller.
    return ['While', null, visit(node.condition), visit(node.body)];
  }

  visitContinueStatement(ast.ContinueStatement node) {
    if (node.label == null) giveup('continue without a label');
    return ['Continue', node.label.name];
  }

  visitTryStatement(ast.TryStatement node) {
    // Try/catch and try/finally are supported.  Try/catch/finally can be
    // desugared into a language with only try/catch and try/finally:
    //
    // try { S0 } catch (e) { S1 } finally { S2 }
    // ==>
    // try {
    //   try { S0 } catch (e) { S1 }
    // } finally {
    //   S2
    // }
    //
    // It would be relatively simple to do that here, but it's not
    // implemented.
    if (node.catchClauses.isEmpty) {
      // This is probably impossible:
      if (node.finallyBlock == null) giveup('try without catch or finally');
      return ['TryFinally', visit(node.body), visit(node.finallyBlock)];
    } else if (node.catchClauses.length == 1) {
      if (node.finallyBlock != null) giveup('try/catch/finally');
      ast.CatchClause clause = node.catchClauses.first;
      return ['TryCatch', visit(node.body), clause.exceptionParameter.name,
              visit(clause.body)];
    } else {
      giveup('multiple catch clauses');
    }
  }
}
