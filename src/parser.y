%{
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <string.h>
#include "compile.h"
#include "jv_alloc.h"
#include "builtin.h"
#define YYMALLOC jv_mem_alloc
#define YYFREE jv_mem_free
%}
%code requires {
#include "locfile.h"
struct lexer_param;

#define YYLTYPE location
#define YYLLOC_DEFAULT(Loc, Rhs, N)             \
  do {                                          \
    if (N) {                                    \
      (Loc).start = YYRHSLOC(Rhs, 1).start;     \
      (Loc).end = YYRHSLOC(Rhs, N).end;         \
    } else {                                    \
      (Loc).start = YYRHSLOC(Rhs, 0).end;       \
      (Loc).end = YYRHSLOC(Rhs, 0).end;         \
    }                                           \
  } while (0)
}

%locations
%define parse.error verbose
%define api.pure
%union {
  jv literal;
  block blk;
}

%destructor { jv_free($$); } <literal>
%destructor { block_free($$); } <blk>

%parse-param {block* answer}
%parse-param {int* errors}
%parse-param {struct locfile* locations}
%parse-param {struct lexer_param* lexer_param_ptr}
%lex-param {block* answer}
%lex-param {int* errors}
%lex-param {struct locfile* locations}
%lex-param {struct lexer_param* lexer_param_ptr}


%token INVALID_CHARACTER
%token <literal> IDENT
%token <literal> FIELD
%token <literal> BINDING
%token <literal> LITERAL
%token <literal> FORMAT
%token REC ".."
%token SETMOD "%="
%token EQ "=="
%token NEQ "!="
%token DEFINEDOR "//"
%token AS "as"
%token DEF "def"
%token MODULE "module"
%token IMPORT "import"
%token INCLUDE "include"
%token IF "if"
%token THEN "then"
%token ELSE "else"
%token ELSE_IF "elif"
%token REDUCE "reduce"
%token FOREACH "foreach"
%token END "end"
%token AND "and"
%token OR "or"
%token TRY "try"
%token CATCH "catch"
%token LABEL "label"
%token BREAK "break"
%token LOC "$__loc__"
%token SETPIPE "|="
%token SETPLUS "+="
%token SETMINUS "-="
%token SETMULT "*="
%token SETDIV "/="
%token SETDEFINEDOR "//="
%token LESSEQ "<="
%token GREATEREQ ">="
%token ALTERNATION "?//"

%token QQSTRING_START
%token <literal> QQSTRING_TEXT
%token QQSTRING_INTERP_START
%token QQSTRING_INTERP_END
%token QQSTRING_END

/* Instead of raising this, find a way to use precedence to resolve
 * shift-reduce conflicts. */
%expect 0

%precedence FUNCDEF
%right '|'
%left ','
%right "//"
%nonassoc '=' SETPIPE SETPLUS SETMINUS SETMULT SETDIV SETMOD SETDEFINEDOR
%left OR
%left AND
%nonassoc NEQ EQ '<' '>' LESSEQ GREATEREQ
%left '+' '-'
%left '*' '/' '%'
%precedence NONOPT /* non-optional; rules for which a specialized
                      '?' rule should be preferred over Expr '?' */
%precedence '?' '.' '[' FIELD
%precedence "try"
%precedence "catch"


%type <blk> Query Expr Term
%type <blk> DictPairs DictPair DictExpr
%type <blk> ElseBody
%type <blk> String QQString
%type <blk> FuncDef FuncDefs
%type <blk> Module Import Imports ImportWhat ImportFrom
%type <blk> Param Params Arg Args
%type <blk> Patterns RepPatterns Pattern ArrayPats ObjPats ObjPat
%type <literal> Keyword
%type <literal> StringStart
%{
#include "lexer.h"
struct lexer_param {
  yyscan_t lexer;
};
#define FAIL(loc, msg)                                             \
  do {                                                             \
    location l = loc;                                              \
    yyerror(&l, answer, errors, locations, lexer_param_ptr, msg);  \
    /*YYERROR*/;                                                   \
  } while (0)

void yyerror(YYLTYPE* loc, block* answer, int* errors,
             struct locfile* locations, struct lexer_param* lexer_param_ptr, const char *s){
  (*errors)++;
  locfile_locate(locations, *loc, "jq: error: %s", s);
}

int yylex(YYSTYPE* yylval, YYLTYPE* yylloc, block* answer, int* errors,
          struct locfile* locations, struct lexer_param* lexer_param_ptr) {
  yyscan_t lexer = lexer_param_ptr->lexer;
  int tok = jq_yylex(yylval, yylloc, lexer);
  if ((tok == LITERAL || tok == QQSTRING_TEXT) && !jv_is_valid(yylval->literal)) {
    jv msg = jv_invalid_get_msg(jv_copy(yylval->literal));
    if (jv_get_kind(msg) == JV_KIND_STRING) {
      FAIL(*yylloc, jv_string_value(msg));
    } else {
      FAIL(*yylloc, "Invalid literal");
    }
    jv_free(msg);
    jv_free(yylval->literal);
    yylval->literal = jv_null();
  }
  return tok;
}

/* Returns string message if the block is a constant that is not valid as an
 * object key. */
static jv check_object_key(block k) {
  if (block_is_const(k) && block_const_kind(k) != JV_KIND_STRING) {
    char errbuf[15];
    return jv_string_fmt("Cannot use %s (%s) as object key",
        jv_kind_name(block_const_kind(k)),
        jv_dump_string_trunc(block_const(k), errbuf, sizeof(errbuf)));
  }
  return jv_invalid();
}

static block gen_index(block obj, block key) {
  return BLOCK(gen_subexp(key), obj, gen_op_simple(INDEX));
}

static block gen_index_opt(block obj, block key) {
  return BLOCK(gen_subexp(key), obj, gen_op_simple(INDEX_OPT));
}

static block gen_slice_index(block obj, block start, block end, opcode idx_op) {
  block key = BLOCK(gen_subexp(gen_const(jv_object())),
                    gen_subexp(gen_const(jv_string("start"))),
                    gen_subexp(start),
                    gen_op_simple(INSERT),
                    gen_subexp(gen_const(jv_string("end"))),
                    gen_subexp(end),
                    gen_op_simple(INSERT));
  return BLOCK(key, obj, gen_op_simple(idx_op));
}

static block constant_fold(block a, block b, int op) {
  if (!block_is_single(a) || !block_is_const(a) ||
      !block_is_single(b) || !block_is_const(b))
    return gen_noop();

  jv jv_a = block_const(a);
  block_free(a);
  jv jv_b = block_const(b);
  block_free(b);

  jv res = jv_invalid();
  switch (op) {
  case '+': res = binop_plus(jv_a, jv_b); break;
  case '-': res = binop_minus(jv_a, jv_b); break;
  case '*': res = binop_multiply(jv_a, jv_b); break;
  case '/': res = binop_divide(jv_a, jv_b); break;
  case '%': res = binop_mod(jv_a, jv_b); break;
  case EQ: res = binop_equal(jv_a, jv_b); break;
  case NEQ: res = binop_notequal(jv_a, jv_b); break;
  case '<': res = binop_less(jv_a, jv_b); break;
  case '>': res = binop_greater(jv_a, jv_b); break;
  case LESSEQ: res = binop_lesseq(jv_a, jv_b); break;
  case GREATEREQ: res = binop_greatereq(jv_a, jv_b); break;
  }

  if (jv_is_valid(res))
    return gen_const(res);

  return gen_error(jv_invalid_get_msg(res));
}

static block gen_binop(block a, block b, int op) {
  block folded = constant_fold(a, b, op);
  if (!block_is_noop(folded))
    return folded;

  const char* funcname = 0;
  switch (op) {
  case '+': funcname = "_plus"; break;
  case '-': funcname = "_minus"; break;
  case '*': funcname = "_multiply"; break;
  case '/': funcname = "_divide"; break;
  case '%': funcname = "_mod"; break;
  case EQ: funcname = "_equal"; break;
  case NEQ: funcname = "_notequal"; break;
  case '<': funcname = "_less"; break;
  case '>': funcname = "_greater"; break;
  case LESSEQ: funcname = "_lesseq"; break;
  case GREATEREQ: funcname = "_greatereq"; break;
  }
  assert(funcname);

  return gen_call(funcname, BLOCK(gen_lambda(a), gen_lambda(b)));
}

static block gen_format(block a, jv fmt) {
  return BLOCK(a, gen_call("format", gen_lambda(gen_const(fmt))));
}

static block gen_definedor_assign(block object, block val) {
  block tmp = gen_op_var_fresh(STOREV, "tmp");
  return BLOCK(gen_op_simple(DUP),
               val, tmp,
               gen_call("_modify", BLOCK(gen_lambda(object),
                                         gen_lambda(gen_definedor(gen_noop(),
                                                                  gen_op_bound(LOADV, tmp))))));
}

static block gen_update(block object, block val, int optype) {
  block tmp = gen_op_var_fresh(STOREV, "tmp");
  return BLOCK(gen_op_simple(DUP),
               val,
               tmp,
               gen_call("_modify", BLOCK(gen_lambda(object),
                                         gen_lambda(gen_binop(gen_noop(),
                                                              gen_op_bound(LOADV, tmp),
                                                              optype)))));
}

static block gen_loc_object(location *loc, struct locfile *locations) {
  return gen_const(JV_OBJECT(jv_string("file"), jv_copy(locations->fname),
                             jv_string("line"), jv_number(locfile_get_line(locations, loc->start) + 1)));
}

%}

%%
TopLevel:
Module Imports Query {
  *answer = BLOCK($1, $2, gen_op_simple(TOP), $3);
} |
Module Imports FuncDefs {
  *answer = BLOCK($1, $2, $3);
}

Module:
%empty {
  $$ = gen_noop();
} |
"module" Query ';' {
  if (!block_is_const($2)) {
    FAIL(@2, "Module metadata must be constant");
    $$ = gen_noop();
    block_free($2);
  } else if (block_const_kind($2) != JV_KIND_OBJECT) {
    FAIL(@2, "Module metadata must be an object");
    $$ = gen_noop();
    block_free($2);
  } else {
    $$ = gen_module($2);
  }
}

Imports:
%empty {
  $$ = gen_noop();
} |
Import Imports {
  $$ = BLOCK($1, $2);
}

FuncDefs:
%empty {
  $$ = gen_noop();
} |
FuncDef FuncDefs {
  $$ = block_join($1, $2);
}


Query:
FuncDef Query %prec FUNCDEF {
  $$ = block_bind_referenced($1, $2, OP_IS_CALL_PSEUDO);
} |
Expr "as" Patterns '|' Query {
  $$ = gen_destructure($1, $3, $5);
} |
"label" BINDING '|' Query {
  jv v = jv_string_fmt("*label-%s", jv_string_value($2));
  $$ = gen_location(@$, locations, gen_label(jv_string_value(v), $4));
  jv_free($2);
  jv_free(v);
} |
Query '|' Query {
  $$ = block_join($1, $3);
} |
Query ',' Query {
  $$ = gen_both($1, $3);
} |
Expr {
  $$ = $1;
}


Expr:
Expr "//" Expr {
  $$ = gen_definedor($1, $3);
} |
Expr '=' Expr {
  $$ = gen_call("_assign", BLOCK(gen_lambda($1), gen_lambda($3)));
} |
Expr "or" Expr {
  $$ = gen_or($1, $3);
} |
Expr "and" Expr {
  $$ = gen_and($1, $3);
} |
Expr "//=" Expr {
  $$ = gen_definedor_assign($1, $3);
} |
Expr "|=" Expr {
  $$ = gen_call("_modify", BLOCK(gen_lambda($1), gen_lambda($3)));
} |
Expr '+' Expr {
  $$ = gen_binop($1, $3, '+');
} |
Expr "+=" Expr {
  $$ = gen_update($1, $3, '+');
} |
Expr '-' Expr {
  $$ = gen_binop($1, $3, '-');
} |
Expr "-=" Expr {
  $$ = gen_update($1, $3, '-');
} |
Expr '*' Expr {
  $$ = gen_binop($1, $3, '*');
} |
Expr "*=" Expr {
  $$ = gen_update($1, $3, '*');
} |
Expr '/' Expr {
  $$ = gen_binop($1, $3, '/');
} |
Expr '%' Expr {
  $$ = gen_binop($1, $3, '%');
} |
Expr "/=" Expr {
  $$ = gen_update($1, $3, '/');
} |
Expr SETMOD Expr {
  $$ = gen_update($1, $3, '%');
} |
Expr "==" Expr {
  $$ = gen_binop($1, $3, EQ);
} |
Expr "!=" Expr {
  $$ = gen_binop($1, $3, NEQ);
} |
Expr '<' Expr {
  $$ = gen_binop($1, $3, '<');
} |
Expr '>' Expr {
  $$ = gen_binop($1, $3, '>');
} |
Expr "<=" Expr {
  $$ = gen_binop($1, $3, LESSEQ);
} |
Expr ">=" Expr {
  $$ = gen_binop($1, $3, GREATEREQ);
} |
Term %prec NONOPT {
  $$ = $1;
}


Import:
ImportWhat ';' {
  $$ = $1;
} |
ImportWhat Query ';' {
  if (!block_is_const($2)) {
    FAIL(@2, "Module metadata must be constant");
    $$ = gen_noop();
    block_free($1);
    block_free($2);
  } else if (block_const_kind($2) != JV_KIND_OBJECT) {
    FAIL(@2, "Module metadata must be an object");
    $$ = gen_noop();
    block_free($1);
    block_free($2);
  } else {
    $$ = gen_import_meta($1, $2);
  }
}

ImportWhat:
"import" ImportFrom "as" BINDING {
  jv v = block_const($2);
  // XXX Make gen_import take only blocks and the int is_data so we
  // don't have to free so much stuff here
  $$ = gen_import(jv_string_value(v), jv_string_value($4), 1);
  block_free($2);
  jv_free($4);
  jv_free(v);
} |
"import" ImportFrom "as" IDENT {
  jv v = block_const($2);
  $$ = gen_import(jv_string_value(v), jv_string_value($4), 0);
  block_free($2);
  jv_free($4);
  jv_free(v);
} |
"include" ImportFrom {
  jv v = block_const($2);
  $$ = gen_import(jv_string_value(v), NULL, 0);
  block_free($2);
  jv_free(v);
}

ImportFrom:
String {
  if (!block_is_const($1)) {
    FAIL(@1, "Import path must be constant");
    $$ = gen_const(jv_string(""));
    block_free($1);
  } else {
    $$ = $1;
  }
}

FuncDef:
"def" IDENT ':' Query ';' {
  $$ = gen_function(jv_string_value($2), gen_noop(), $4);
  jv_free($2);
} |

"def" IDENT '(' Params ')' ':' Query ';' {
  $$ = gen_function(jv_string_value($2), $4, $7);
  jv_free($2);
}

Params:
Param {
  $$ = $1;
} |
Params ';' Param {
  $$ = BLOCK($1, $3);
}

Param:
BINDING {
  $$ = gen_param_regular(jv_string_value($1));
  jv_free($1);
} |
IDENT {
  $$ = gen_param(jv_string_value($1));
  jv_free($1);
}


StringStart:
FORMAT QQSTRING_START {
  $$ = $1;
} |
QQSTRING_START {
  $$ = jv_string("text");
}


String:
StringStart QQString QQSTRING_END {
  $$ = $2;
  jv_free($1);
};


QQString:
%empty {
  $$ = gen_const(jv_string(""));
} |
QQString QQSTRING_TEXT {
  $$ = gen_binop($1, gen_const($2), '+');
} |
QQString QQSTRING_INTERP_START Query QQSTRING_INTERP_END {
  $$ = gen_binop($1, gen_format($3, jv_copy($<literal>0)), '+');
}


ElseBody:
"elif" Query "then" Query ElseBody {
  $$ = gen_cond($2, $4, $5);
} |
"else" Query "end" {
  $$ = $2;
} |
"end" {
  $$ = gen_noop();
}


Term:
'.' {
  $$ = gen_noop();
} |
REC {
  $$ = gen_call("recurse", gen_noop());
} |
BREAK BINDING {
  jv v = jv_string_fmt("*label-%s", jv_string_value($2));     // impossible symbol
  $$ = gen_location(@$, locations,
                    BLOCK(gen_op_unbound(LOADV, jv_string_value(v)),
                    gen_call("error", gen_noop())));
  jv_free(v);
  jv_free($2);
} |
BREAK error {
  FAIL(@$, "break requires a label to break to");
  $$ = gen_noop();
} |
Term FIELD '?' {
  $$ = gen_index_opt($1, gen_const($2));
} |
FIELD '?' {
  $$ = gen_index_opt(gen_noop(), gen_const($1));
} |
Term '.' String '?' {
  $$ = gen_index_opt($1, $3);
} |
'.' String '?' {
  $$ = gen_index_opt(gen_noop(), $2);
} |
Term FIELD %prec NONOPT {
  $$ = gen_index($1, gen_const($2));
} |
FIELD %prec NONOPT {
  $$ = gen_index(gen_noop(), gen_const($1));
} |
Term '.' String %prec NONOPT {
  $$ = gen_index($1, $3);
} |
'.' String %prec NONOPT {
  $$ = gen_index(gen_noop(), $2);
} |
'.' error {
  FAIL(@$, "try .[\"field\"] instead of .field for unusually named fields");
  $$ = gen_noop();
} |
'.' IDENT error {
  jv_free($2);
  FAIL(@$, "try .[\"field\"] instead of .field for unusually named fields");
  $$ = gen_noop();
} |
/* FIXME: string literals */
Term '[' Query ']' '?' {
  $$ = gen_index_opt($1, $3);
} |
Term '[' Query ']' %prec NONOPT {
  $$ = gen_index($1, $3);
} |
Term '.' '[' Query ']' '?' {
  $$ = gen_index_opt($1, $4);
} |
Term '.' '[' Query ']' %prec NONOPT {
  $$ = gen_index($1, $4);
} |
Term '[' ']' '?' {
  $$ = block_join($1, gen_op_simple(EACH_OPT));
} |
Term '[' ']' %prec NONOPT {
  $$ = block_join($1, gen_op_simple(EACH));
} |
Term '.' '[' ']' '?' {
  $$ = block_join($1, gen_op_simple(EACH_OPT));
} |
Term '.' '[' ']' %prec NONOPT {
  $$ = block_join($1, gen_op_simple(EACH));
} |
Term '[' Query ':' Query ']' '?' {
  $$ = gen_slice_index($1, $3, $5, INDEX_OPT);
} |
Term '[' Query ':' ']' '?' {
  $$ = gen_slice_index($1, $3, gen_const(jv_null()), INDEX_OPT);
} |
Term '[' ':' Query ']' '?' {
  $$ = gen_slice_index($1, gen_const(jv_null()), $4, INDEX_OPT);
} |
Term '[' Query ':' Query ']' %prec NONOPT {
  $$ = gen_slice_index($1, $3, $5, INDEX);
} |
Term '[' Query ':' ']' %prec NONOPT {
  $$ = gen_slice_index($1, $3, gen_const(jv_null()), INDEX);
} |
Term '[' ':' Query ']' %prec NONOPT {
  $$ = gen_slice_index($1, gen_const(jv_null()), $4, INDEX);
} |
Term '?' {
  $$ = gen_try($1, gen_op_simple(BACKTRACK));
} |
LITERAL {
  $$ = gen_const($1);
} |
String {
  $$ = $1;
} |
FORMAT {
  $$ = gen_format(gen_noop(), $1);
} |
'-' Term {
  $$ = BLOCK($2, gen_call("_negate", gen_noop()));
} |
'(' Query ')' {
  $$ = $2;
} |
'[' Query ']' {
  $$ = gen_collect($2);
} |
'[' ']' {
  $$ = gen_const(jv_array());
} |
'{' DictPairs '}' {
  block o = gen_const_object($2);
  if (o.first != NULL)
    $$ = o;
  else
    $$ = BLOCK(gen_subexp(gen_const(jv_object())), $2, gen_op_simple(POP));
} |
"reduce" Expr "as" Patterns '(' Query ';' Query ')' {
  $$ = gen_reduce($2, $4, $6, $8);
} |
"foreach" Expr "as" Patterns '(' Query ';' Query ';' Query ')' {
  $$ = gen_foreach($2, $4, $6, $8, $10);
} |
"foreach" Expr "as" Patterns '(' Query ';' Query ')' {
  $$ = gen_foreach($2, $4, $6, $8, gen_noop());
} |
"if" Query "then" Query ElseBody {
  $$ = gen_cond($2, $4, $5);
} |
"if" Query "then" error {
  FAIL(@$, "Possibly unterminated 'if' statement");
  $$ = $2;
} |
"try" Expr "catch" Expr {
  $$ = gen_try($2, $4);
} |
"try" Expr "catch" error {
  FAIL(@$, "Possibly unterminated 'try' statement");
  $$ = $2;
} |
"try" Expr {
  $$ = gen_try($2, gen_op_simple(BACKTRACK));
} |
/*
 * This `$$$$varname` hack is strictly private to jq builtins.  DO NOT USE!!
 *
 * This is used in `_modify`, in src/builtin.jq, to avoid holding on to a
 * reference to `.`.
 *
 * We could just have the compiler emit bytecode for `_modify` so it can use
 * LOADVN w/o needing jq syntax for LOADVN.
 *
 * This syntax, `$$$$varname`, violates referential transparency: it has
 * side-effects that are surprising.
 *
 * DO NOT USE!!  I will break your jq code if you do use this outside
 * src/builtin.jq.
 */
'$' '$' '$' BINDING {
  $$ = gen_location(@$, locations, gen_op_unbound(LOADVN, jv_string_value($4)));
  jv_free($4);
} |
BINDING {
  $$ = gen_location(@$, locations, gen_op_unbound(LOADV, jv_string_value($1)));
  jv_free($1);
} |
"$__loc__" {
  $$ = gen_loc_object(&@$, locations);
} |
IDENT {
  const char *s = jv_string_value($1);
  if (strcmp(s, "false") == 0)
    $$ = gen_const(jv_false());
  else if (strcmp(s, "true") == 0)
    $$ = gen_const(jv_true());
  else if (strcmp(s, "null") == 0)
    $$ = gen_const(jv_null());
  else
    $$ = gen_location(@$, locations, gen_call(s, gen_noop()));
  jv_free($1);
} |
IDENT '(' Args ')' {
  $$ = gen_call(jv_string_value($1), $3);
  $$ = gen_location(@1, locations, $$);
  jv_free($1);
} |
'(' error ')' { $$ = gen_noop(); } |
'[' error ']' { $$ = gen_noop(); } |
Term '[' error ']' { $$ = $1; } |
'{' error '}' { $$ = gen_noop(); }

Args:
Arg {
  $$ = $1;
} |
Args ';' Arg {
  $$ = BLOCK($1, $3);
}

Arg:
Query {
  $$ = gen_lambda($1);
}

RepPatterns:
RepPatterns "?//" Pattern {
  $$ = BLOCK($1, gen_destructure_alt($3));
} |
Pattern {
  $$ = gen_destructure_alt($1);
}

Patterns:
RepPatterns "?//" Pattern {
  $$ = BLOCK($1, $3);
} |
Pattern {
  $$ = $1;
}

Pattern:
BINDING {
  $$ = gen_op_unbound(STOREV, jv_string_value($1));
  jv_free($1);
} |
'[' ArrayPats ']' {
  $$ = BLOCK($2, gen_op_simple(POP));
} |
'{' ObjPats '}' {
  $$ = BLOCK($2, gen_op_simple(POP));
}

ArrayPats:
Pattern {
  $$ = gen_array_matcher(gen_noop(), $1);
} |
ArrayPats ',' Pattern {
  $$ = gen_array_matcher($1, $3);
}

ObjPats:
ObjPat {
  $$ = $1;
} |
ObjPats ',' ObjPat {
  $$ = BLOCK($1, $3);
}

ObjPat:
BINDING {
  $$ = gen_object_matcher(gen_const($1), gen_op_unbound(STOREV, jv_string_value($1)));
} |
BINDING ':' Pattern {
  $$ = gen_object_matcher(gen_const($1), BLOCK(gen_op_simple(DUP), gen_op_unbound(STOREV, jv_string_value($1)), $3));
} |
IDENT ':' Pattern {
  $$ = gen_object_matcher(gen_const($1), $3);
} |
Keyword ':' Pattern {
  $$ = gen_object_matcher(gen_const($1), $3);
} |
String ':' Pattern {
  $$ = gen_object_matcher($1, $3);
} |
'(' Query ')' ':' Pattern {
  jv msg = check_object_key($2);
  if (jv_is_valid(msg)) {
    FAIL(@2, jv_string_value(msg));
  }
  jv_free(msg);
  $$ = gen_object_matcher($2, $5);
} |
error ':' Pattern {
  FAIL(@$, "May need parentheses around object key expression");
  $$ = $3;
}

Keyword:
"as" {
  $$ = jv_string("as");
} |
"def" {
  $$ = jv_string("def");
} |
"module" {
  $$ = jv_string("module");
} |
"import" {
  $$ = jv_string("import");
} |
"include" {
  $$ = jv_string("include");
} |
"if" {
  $$ = jv_string("if");
} |
"then" {
  $$ = jv_string("then");
} |
"else" {
  $$ = jv_string("else");
} |
"elif" {
  $$ = jv_string("elif");
} |
"reduce" {
  $$ = jv_string("reduce");
} |
"foreach" {
  $$ = jv_string("foreach");
} |
"end" {
  $$ = jv_string("end");
} |
"and" {
  $$ = jv_string("and");
} |
"or" {
  $$ = jv_string("or");
} |
"try" {
  $$ = jv_string("try");
} |
"catch" {
  $$ = jv_string("catch");
} |
"label" {
  $$ = jv_string("label");
} |
"break" {
  $$ = jv_string("break");
}


DictPairs:
%empty {
  $$ = gen_noop();
} |
DictPair {
  $$ = $1;
} |
DictPair ',' DictPairs {
  $$ = block_join($1, $3);
}

DictPair:
IDENT ':' DictExpr {
  $$ = gen_dictpair(gen_const($1), $3);
} |
Keyword ':' DictExpr {
  $$ = gen_dictpair(gen_const($1), $3);
} |
String ':' DictExpr {
  $$ = gen_dictpair($1, $3);
} |
String {
  $$ = gen_dictpair($1, BLOCK(gen_op_simple(POP), gen_op_simple(DUP2),
                              gen_op_simple(DUP2), gen_op_simple(INDEX)));
} |
BINDING ':' DictExpr {
  $$ = gen_dictpair(gen_location(@$, locations, gen_op_unbound(LOADV, jv_string_value($1))),
                    $3);
  jv_free($1);
} |
BINDING {
  $$ = gen_dictpair(gen_const($1),
                    gen_location(@$, locations, gen_op_unbound(LOADV, jv_string_value($1))));
} |
IDENT {
  $$ = gen_dictpair(gen_const(jv_copy($1)),
                    gen_index(gen_noop(), gen_const($1)));
} |
"$__loc__" {
  $$ = gen_dictpair(gen_const(jv_string("__loc__")),
                    gen_loc_object(&@$, locations));
} |
Keyword {
  $$ = gen_dictpair(gen_const(jv_copy($1)),
                    gen_index(gen_noop(), gen_const($1)));
} |
'(' Query ')' ':' DictExpr {
  jv msg = check_object_key($2);
  if (jv_is_valid(msg)) {
    FAIL(@2, jv_string_value(msg));
  }
  jv_free(msg);
  $$ = gen_dictpair($2, $5);
} |
error ':' DictExpr {
  FAIL(@1, "May need parentheses around object key expression");
  $$ = $3;
}

DictExpr:
DictExpr '|' DictExpr {
  $$ = block_join($1, $3);
} |
Expr {
  $$ = $1;
}
%%

int jq_parse(struct locfile* locations, block* answer) {
  struct lexer_param scanner;
  YY_BUFFER_STATE buf;
  jq_yylex_init_extra(0, &scanner.lexer);
  buf = jq_yy_scan_bytes(locations->data, locations->length, scanner.lexer);
  int errors = 0;
  *answer = gen_noop();
  yyparse(answer, &errors, locations, &scanner);
  jq_yy_delete_buffer(buf, scanner.lexer);
  jq_yylex_destroy(scanner.lexer);
  if (errors > 0) {
    block_free(*answer);
    *answer = gen_noop();
  }
  return errors;
}

int jq_parse_library(struct locfile* locations, block* answer) {
  int errs = jq_parse(locations, answer);
  if (errs) return errs;
  if (block_has_main(*answer)) {
    locfile_locate(locations, UNKNOWN_LOCATION, "jq: error: library should only have function definitions, not a main expression");
    return 1;
  }
  assert(block_has_only_binders_and_imports(*answer, OP_IS_CALL_PSEUDO));
  return 0;
}
