#lang racket
(#%provide (all-defined))
(#%require (lib "eopl.ss" "eopl"))

(#%require "lp-env-values.rkt")
(#%require "lp-lang.rkt")

;given one or more arguments this function will return a flat list
(define (flat-list el1 . rest)
  (flatten (list el1 rest))
  )

;===============================================================================
;================================ Value-of =====================================
;===============================================================================
;value-of takes as a parameter an AST resulted from a call to the
;create-ast function.
(define (run program-string)
  (if (string? program-string)
      (value-of (create-ast program-string) (empty-env))
      (raise (string-append "expected a program as string, got: " (~a program-string)))
      )  
  )

(define (value-of ast env)
  (cond 
    [(program? ast) (value-of-program ast env)]
    [(expr? ast) (value-of-expr ast env)]
    [(var-expr? ast) (value-of-var ast env)]
    [else (raise (~a "Unimplemented ast node: " ~a ast))]
    )
  )
;================================= program =====================================
(define (value-of-program prog env)
  (cases program prog
    (a-program
     (fun-defs expr rest-of-expressions)
     ;given a non-predicate function, andmap will apply the function
     ;to every element in the list and then return the value of
     ;applying the function on the last element.
     (let ([new-env (foldl value-of env fun-defs)])
      (andmap (lambda (ex) (value-of ex new-env))
             (flat-list expr rest-of-expressions))
     )
    )
  )
  )

;=================================== expr =======================================
(define (value-of-expr ex env)
  (or (expr? ex) (raise (string-append "value-of-expr error: expected an expression, got " (~a ex))))
  (cases expr ex
    (num-expr (n) (num-val n))
    
    (up-expr
     (num)
     (step-val (up-step (num-val->n (value-of num env)))))
    
    (down-expr
     (num)
     (step-val (down-step (num-val->n (value-of num env)))))
    
    (left-expr
     (num)
     (step-val (left-step (num-val->n (value-of num env)))))
    
    (right-expr
     (num)
     (step-val (right-step (num-val->n (value-of num env)))))
    
    (iden-expr
     (var-name)
     (apply-env env var-name))
    
    ;(expr ("[" expr expr "]") point-expr)
    (point-expr
     (x y)
     (point-val (point (num-val->n (value-of x env)) (num-val->n (value-of y env))))
     )
    
    ;(expr ("move" "(" expr (arbno expr)")") move-expr)
    (move-expr
     (point-expr first-move rest-of-moves)
     (letrec
         ([start-p (point-val->p (value-of point-expr env))]
          [all-moves-as-expr (map (lambda (ex) (value-of ex env)) (flat-list first-move rest-of-moves))]
          [all-moves-step (map step-val->st all-moves-as-expr)]
          [final-p (foldl move start-p all-moves-step)])
       (point-val final-p)
       )
     )
    
    (add-expr
     (lhs rhs)
     (letrec
         ([l-step-val (value-of lhs env)]
          [r-step-val (value-of rhs env)]
          [l-step (step-val->st l-step-val)]
          [r-step (step-val->st r-step-val)]
          [res (+ (get-axis-value l-step) (get-axis-value r-step))])
       (cond
         [(and (valid-steps-for-add? l-step r-step) 
               (or (left-step? l-step) (right-step? l-step))) 
          (get-horizontal-step res)
          ]
         [(and (valid-steps-for-add? l-step r-step) (or (up-step? l-step) (down-step? l-step)))
          (get-vertical-step res)
          ]
         [else (raise "invalid args in add")]
         )
       )
     )
    
    (origin-expr 
     (p-expr)
     (bool-val (equal? (point-val->p (value-of p-expr env)) (point 0 0)))
     )
    
    (if-expr 
     (cond then-exp else-exp)
     (let
         ([c-val (bool-val->b (value-of cond env))])
       (if c-val
           (value-of then-exp env)
           (value-of else-exp env))
       )
     )
    
    (block-expr
     (list-of-var-decl list-of-expr)
     (let ([new-env (foldl value-of env list-of-var-decl)])
       (andmap (lambda (ex) (value-of ex new-env))
               list-of-expr)
       )
     )
        
    ;the only thing we have to do when we encounter a fun-expr
    ;is return the function as a value. We store the environment in which
    ;the function was created.
    (fun-expr
     (vars-expr body-expr)
     (proc-val (procedure vars-expr body-expr env))
     )

    (fun-call-expr
     (fun-exp argv-expr)
     (letrec
         ([fun (proc-val->proc (value-of fun-exp env))]
          [var-names (proc->vars fun)]
          ;we evaluate the values of the parameters in the current environment
          [argument-values (map (lambda (x) (value-of x env)) argv-expr)]
          [fun-body (proc->body fun)]
          [proc-env (proc->env fun)]
          ;we extend the environment in which the function was created with all
          ;the paramater names -> values pairs.
          [new-env 
           (begin
             (or (equal? (length var-names) (length argument-values))
                 (raise (~a "arity mismatch. expected "(length var-names) " arguments, received " (length argument-values))))
             (extend-env-multiple-times var-names argument-values proc-env FINAL)
             )])
       
       ;we evaluate the body of the procedure in this new environment.
       (value-of fun-body new-env)
       )
     )
    
    (else (raise (~a "value-of-expr error: unimplemented expression: " ex)))
    )
  )

(define (extend-env-multiple-times list-of-syms list-of-vals init-env final?)
  (if (equal? (length list-of-syms) 0)
      init-env
      (extend-env-multiple-times (cdr list-of-syms) 
                                 (cdr list-of-vals)
                                 (extend-env-wrapper (car list-of-syms)
                                                     (car list-of-vals)
                                                     init-env
                                                     final?)
                                 final?))
  )


(define (move st start-p)
  (cases step st
    (up-step (st)
             (point (point->x start-p) (+ (point->y start-p) st)))
    
    (down-step (st)
               (point (point->x start-p) (- (point->y start-p) st)))
    
    (left-step (st)
               (point ( - (point->x start-p) st) (point->y start-p)))
    
    (right-step (st)
                (point ( + (point->x start-p) st) (point->y start-p)))
    
    )
  )


;========================= helpers for add ================================
(define (valid-steps-for-add? st1 st2)
  (or 
   (and (up-step? st1) (up-step? st2))
   (and (down-step? st1) (down-step? st2))
   (and (up-step? st1) (down-step? st2))
   (and (down-step? st1) (up-step? st2))
   
   (and (left-step? st1) (left-step? st2))
   (and (right-step? st1) (right-step? st2))
   (and (left-step? st1) (right-step? st2))
   (and (right-step? st1) (left-step? st2))
   )
  )

(define (get-axis-value st)
  (cases step st
    (up-step (st) st)
    (down-step (st) (* -1 st))
    (left-step (st) (* -1 st))
    (right-step (st) st)
    )
  )

(define (get-vertical-step num)
  (if (positive? num)
      (step-val (up-step num)) 
      (step-val (down-step (* -1 num)))
      )         
  )

(define (get-horizontal-step num)
  (if (positive? num)
      (step-val (right-step num)) 
      (step-val (left-step (* -1 num)))
      )         
  )



;=================================== var =======================================
(define (value-of-var v-ex env)
  (or (var-expr? v-ex) (invalid-args-exception "value-of-var" "var-expr?" v-ex))
  (cases var-expr v-ex
    (val
     (iden val-of-iden)
     (extend-env-wrapper iden (value-of val-of-iden env) env NON-FINAL))
    
    (final-val
     (iden val-of-iden)
     (extend-env-wrapper iden (value-of val-of-iden env) env FINAL))
        ;we simply extend the environment with a procedure-name, proc-val
    ;pair.
    (def-fun
      (fun-name fun-params body)
      (extend-env-wrapper fun-name (proc-val (procedure fun-params body env)) env FINAL)
      )
    
    (else (raise (~a "value-of-var error: unimplemented expression: " v-ex)))
    )
  )
