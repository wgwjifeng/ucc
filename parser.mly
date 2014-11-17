%{
  open Syntax
%}

%token <int> INT
%token <string> ID
%token TINT
%token IF ELSE RETURN WHILE
%token LPAREN RPAREN
%token LBRACE RBRACE
%token PLUS MINUS MOD EQ LT
%token SEMICOLON COMMA
%token SUBST
%token EOF

%left EQ
%left LT
%left PLUS MINUS
%right MOD
%start <Syntax.decl list> main

%%

main:
| decl* EOF {$1}


decl:
| decl_fun  { $1}
| decl_vars { $1 }


decl_vars:
| t= typeref; vlist= separated_nonempty_list(COMMA, ID); SEMICOLON
  {DVars(t, List.map (fun x -> Name x) vlist, ($startpos, $endpos))}

decl_fun:
| t=typeref; name=ID; LPAREN; p=params; RPAREN; b=block
  {DFun(t, Name name, p, b, ($startpos, $endpos))}

params:
| typeref ID {[($1, (Syntax.Name $2))]}

typeref:
| TINT { TInt }

block:
| LBRACE stmt* RBRACE {$2}

stmt:
| SEMICOLON {SNil}
| expr SEMICOLON {SExpr($1)}
| WHILE LPAREN expr RPAREN block {SWhile($3, $5)}
| IF LPAREN expr RPAREN block {SIf($3, $5)}
| IF LPAREN expr RPAREN block ELSE block {SIfElse($3, $5, $7)}
| RETURN expr SEMICOLON {SReturn $2}

expr:
| LPAREN expr RPAREN
    { $2 }
| expr PLUS expr
    { EAdd($1, $3)}
| expr MINUS expr
    { ESub($1, $3)}
| expr MOD expr
    { EMod($1, $3)}
| expr EQ expr
    { EEq($1, $3)}
| expr LT expr
    { ELt($1, $3)}
| ID LPAREN args RPAREN
    { EApp(Name $1, $3) }
| ID
    { EVar (Name $1)}
| value
    { EConst($1)}
value:
| INT {VInt($1)}

args:
| expr
    {[$1]}
| expr COMMA args
    {$1::$3}
