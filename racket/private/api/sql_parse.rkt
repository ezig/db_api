#lang racket

(provide parse-where
         restrict-where
         empty-where
         validate-update
         validate-select
         validate-aggr
         parse-groupby
         parse-having)

(require "util.rkt")
(require parser-tools/yacc
         parser-tools/lex
         (prefix-in : parser-tools/lex-sre))

(define-tokens value-tokens (IDENTIFIER NUM STR COMP ADDOP MULOP AGG))
(define-empty-tokens op-tokens
  (OP CP               ; ( )
      AND              ; and
      OR               ; or
      COMMA            ; ,
      EOF))
                                        
(define-lex-abbrevs
  [letter (:or (:/ "a" "z") (:/ #\A #\Z) )]
  [digit (:/ #\0 #\9)]
  [aggr (:or "min" "MIN"
             "max" "MAX"
             "sum" "SUM"
             "avg" "AVG"
             "count" "COUNT")]
  [identifier (:: (:or letter #\_) (:* (:or letter digit #\_)))])

(define sql-lexer
  (lexer-src-pos
   [(eof) 'EOF]
   [(:or #\tab #\space)
    (return-without-pos (sql-lexer input-port))]
   [(:or "+" "-") (token-ADDOP (string->symbol lexeme))]
   [(:or "*" "/") (token-MULOP (string->symbol lexeme))]
   [(:or "<" ">" "=" "!=" "<=" ">=") (token-COMP (string->symbol lexeme))]
   ["," 'COMMA]
   ["(" 'OP]
   [")" 'CP]
   ["and" 'AND]
   ["or" 'OR]
   [aggr (token-AGG (string->symbol (string-upcase lexeme)))]
   [identifier (token-IDENTIFIER lexeme)]
   [(:: #\' (:* any-char) #\')
    (token-STR (substring lexeme 1 (- (string-length lexeme) 1)))]
   [(:+ digit) (token-NUM (string->number lexeme))]
   [(:: (:+ digit) #\. (:* digit)) (token-NUM (string->number lexeme))]))

(define/contract (get-type e)
      (-> (or/c exp? atom? aggop?) symbol?)
  (match e
    [(atom t _ _ ) t]
    [(exp _ t _ _) t]
    [(aggop _ t _) t]))

(define/contract (build-parser p-type)
  (-> (one-of/c 'where 'update 'select 'aggr 'having) any/c)
  (λ (type-map [updatable null])
    (define (parse-cond cop e1 e2)
      (let ([type1 (get-type e1)]
            [type2 (get-type e2)])
        (if (eq? type1 type2)
            (case p-type
              [(where) (condexp cop e1 e2)]
              [(having) (condexp cop e1 e2)]
              [(select) (condexp cop e1 e2)]
              [(update)
               (if (eq? cop '=)
                   (if (and (atom? e1) (atom-is-id? e1) (member (atom-val e1) updatable))                    
                       (condexp cop e1 e2)
                       (error 'parser
                              "lhs ~a of assignment in update does not refer to updatable column" e1))
                   (error 'parser "illegal comparison ~a in update" cop))])
            (error 'parser
                   "type error comparing ~a to ~a" type1 type2))))
    (define (parse-binop op e1 e2)
      (let ([type1 (get-type e1)]
            [type2 (get-type e2)])
        (if (and (eq? type1 type2)
                 (or (eq? type1 'num) (eq? op '+)))
            (exp op type1 e1 e2)
            (error 'parser "illegal types ~a and ~a to binop ~a"
                   type1 type2 op))))
    (parser
     (src-pos)
     (start clause)
     (end EOF)
     (tokens value-tokens op-tokens)
     (error
      (λ (tok-ok? tok-name tok-value start-pos end-pos)
        (error p-type "Syntax error: unexpected token ~a (\"~a\") at ~a"
               tok-name tok-value (position-offset start-pos))))
     (precs (left COMMA)
            (left OR)
            (left AND)
            (left ADDOP)
            (left MULOP))
     (grammar
      (condexp
        [(OP condexp CP) $2]
        [(exp COMP exp) (parse-cond $2 $1 $3)])
      (clause
       [(condexp) $1]
       [(exp) (if (member p-type (list 'select 'aggr))
                  $1
                  (error 'p-type
                         "illegal clause without condition for parser type ~a" p-type))]
       [(clause COMMA clause) (if (member p-type (list 'where 'having))
                                  (error p-type
                                         "illegal token , for parser type where")
                                  (clause 'COMMA $1 $3))]
       [(clause AND clause) (if (member p-type (list 'where 'having))
                                (clause 'AND $1 $3)
                                (error p-type
                                       "illegal token and for parser type ~a" p-type))]
       [(clause OR clause) (if (member p-type (list 'where 'having))
                               (clause 'OR $1 $3)
                               (error p-type
                                      "illegal token or for parser type ~a" p-type))])   
      (atom
       [(STR) (atom 'str #f $1)]
       [(NUM) (atom 'num #f $1)]
       [(IDENTIFIER) (with-handlers ([exn:fail?
                                      (λ (e)
                                        (error p-type
                                               "undefined identifier ~a" $1))])
                       (atom (hash-ref type-map $1) #t $1))]
       [(OP exp CP) $2])
      (aggop
       [(AGG OP atom CP) (if (member p-type (list 'aggr 'having))
                             (aggop $1 'num $3) ; Type of aggregation is always number
                             (error 'parser
                                    "aggregation expression not permitted in ~a" p-type))])
      (exp
       [(atom) $1]
       [(aggop) $1]
       [(exp ADDOP exp) (parse-binop $2 $1 $3)]
       [(exp MULOP exp) (parse-binop $2 $1 $3)])))))

(define/contract (select-to-type-map ast)
  (-> ast? hash?)
  (define (aux t)
    (match t
      [(clause connector c1 c2) (append (aux c1) (aux c2))]
      [(condexp cop e1 e2) (list 'num)] ; comparison in select leads to bool column
      [(exp op type e1 e2) (list type)]
      [(aggop _ type _) (list type)]
      [(atom type is-id? val) (list type)]))
  (let* ([root (ast-root ast)]
         [type-list (aux root)]
         ; XXX fix this for non simple columns which don't behave well with names
         [colnames (map string-trim (string-split (ast-to-string ast) ","))])
    (make-immutable-hash (zip colnames type-list))))

(define (lexer-thunk port)
  (port-count-lines! port)
  (λ () (sql-lexer port)))

(define where-parser (build-parser 'where))
(define update-parser (build-parser 'update))
(define select-parser (build-parser 'select))
(define aggr-parser (build-parser 'aggr))
(define having-parser (build-parser 'having))

(define (parse-clause str clause-type p-args)
     (if (or (null? str) (not (non-empty-string? str)))
        (ast 'where null)
        (let ([oip (open-input-string str)]
              [parser (case clause-type
                        [(where) where-parser]
                        [(update) update-parser]
                        [(select) select-parser]
                        [(aggr) aggr-parser]
                        [(having) having-parser]
                        [else (error 'parse-clause "unsupported clause type ~a" clause-type)])])
          (begin0
            (ast clause-type ((apply parser p-args) (lexer-thunk oip)))
            (close-input-port oip)))))

(define (parse-where str type-map)
  (parse-clause str 'where (list type-map)))
(define (parse-update str type-map updatable)
  (parse-clause str 'update (list type-map updatable)))
(define (parse-select str type-map)
  (parse-clause str 'select (list type-map)))
(define (parse-aggr str type-map)
  (parse-clause str 'aggr (list type-map)))
; Valid group-bys are the same as valid select for now
(define (parse-groupby str type-map)
  (parse-clause str 'select (list type-map)))
(define (parse-having str type-map)
  (parse-clause str 'having (list type-map)))

(define empty-where
  (ast 'where null))

(define/contract (restrict-where where-ast restrict-str type-map)
  (-> ast? string? hash? ast?)
  (let ([restrict-ast (parse-where restrict-str type-map)]
        [old-root (ast-root where-ast)])
    (if (null? old-root)
        restrict-ast
        (ast 'where (clause 'AND old-root (ast-root restrict-ast))))))

(define (validate-update str updatable type-map)
  (parse-update str type-map updatable))

(define (validate-select str type-map)
  (-> string? hash? hash?)
  (select-to-type-map (parse-select str type-map)))

(define (validate-aggr str type-map)
  (-> string? hash? hash?)
  (select-to-type-map (parse-aggr str type-map)))
