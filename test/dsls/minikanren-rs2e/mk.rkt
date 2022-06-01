#lang racket/base

(provide (all-defined-out)
         (for-space mk quasiquote))

(require "../../../main.rkt"
         (for-syntax
          racket/base
          syntax/parse
          syntax/id-table))

;;
;; Core syntax
;;

(begin-for-syntax
  (define-syntax-class quote-lit
    (pattern (~literal quote)))
  (define-syntax-class cons-lit
    (pattern (~literal cons))))

(define-hosted-syntaxes
  (binding-class term-variable #:description "miniKanren term variable")
  (binding-class relation-name #:description "miniKanren relation name")
  
  (extension-class term-macro
                   #:binding-space mk)
  (extension-class goal-macro)
  
  (nonterminal quoted
    #:description "quoted value"
    n:number
    s:id
    ()
    (a:quoted . d:quoted))

  (nonterminal term
    #:description "miniKanren term"
    #:allow-extension term-macro
    
    n:number
    x:term-variable
    (q:quote-lit t:quoted)
    (c:cons-lit t1:term t2:term))

  (nonterminal goal
    #:description "miniKanren goal"
    #:allow-extension goal-macro

    ;; TODO: unwrap, after adding core support.
    (succeed)
    (fail)
    
    (== t1:term t2:term)

    (disj2 g1:goal g2:goal)
    (conj2 g1:goal g2:goal)
  
    (fresh1 (x:term-variable) b:goal)
    #:binding {(bind x) b}

    (project (x:term-variable ...) e:expr ...)
    #:binding (host e)
    
    (ifte g1:goal g2:goal g3:goal)
    (once g:goal)

    (r:relation-name t:term ...+)))

;;
;; Surface syntax
;;

;; TODO: use syntax-parse and syntax classes for better errors.

(define-syntax define-syntax/space
  (syntax-parser
    [(_ name space rhs)
     #`(define-syntax #,((make-interned-syntax-introducer (syntax-e #'space)) #'name) rhs)]))

(define-syntax/space quasiquote mk
  (term-macro
   (syntax-parser 
     [(~describe
       "`<datum>"
       (_ q))
      (let recur ([stx #'q])
        (syntax-parse stx #:datum-literals (unquote)
          [(unquote e) #'e]
          [(unquote . rest)
           (raise-syntax-error 'unquote "bad unquote syntax" stx)]
          [(a . d) #`(cons #,(recur #'a) #,(recur #'d))]
          [(~or* v:identifier v:number) #'(quote v)]
          [() #'(quote ())]))])))

(define-syntax disj
  (goal-macro
   (syntax-rules ()
     ((disj) (fail))
     ((disj g) g)
     ((disj g0 g ...) (disj2 g0 (disj g ...))))))

(define-syntax conj
  (goal-macro
   (syntax-rules ()
     ((conj) (succeed))
     ((conj g) g)
     ((conj g0 g ...) (conj2 g0 (conj g ...))))))

(define-syntax fresh
  (goal-macro
   (syntax-rules ()
     ((fresh () g ...) (conj g ...))
     ((fresh (x0 x ...) g ...)
      (fresh1 (x0)
              (fresh (x ...)
                g ...))))))

(define-syntax conde
  (goal-macro
   (syntax-rules ()
     ((conde (g ...) ...)
      (disj (conj g ...) ...)))))

(define-syntax conda
  (goal-macro
   (syntax-rules ()
     ((conda (g0 g ...)) (conj g0 g ...))
     ((conda (g0 g ...) ln ...)
      (ifte g0 (conj g ...) (conda ln ...))))))

(define-syntax condu
  (goal-macro
   (syntax-rules ()
     ((condu (g0 g ...) ...)
      (conda ((once g0) g ...) ...)))))

;;
;; Interface macros
;;

(define-host-interface/definitions
  (core-defrel (name:relation-name x:term-variable ...) g:goal)
  #:binding [(export name) {(bind x) g}]
  
  #:with compiled-name (compile-binder! compiled-names #'name)
  #:with (compiled-x ...) (compile-binders! compiled-names #'(x ...))
  
  #`(define (compiled-name compiled-x ...)
      (lambda (s)
        (lambda ()
          (#,(compile-goal #'g) s)))))

(define-host-interface/expression
  (core-run n:expr q:term-variable g:goal)
  #:binding {(bind q) g}

  #:with compiled-q (compile-binder! compiled-names #'q)
  
  #`(let ([compiled-q (var 'q)])
      (map (reify compiled-q)
           (run-goal n #,(compile-goal #'g)))))

;;
;; Surface syntax for interface macros
;;

(define-syntax defrel
  (syntax-rules ()
    [(defrel (name x ...) g ...)
     (core-defrel (name x ...) (conj g ...))]))

(define-syntax run
  (syntax-rules ()
    [(run n (x0 x ...) g ...)
     (run n q (fresh (x0 x ...)
                (== `(,x0 ,x ...) q) g ...))]
    [(run n q g ...)
     (core-run n q (conj g ...))]))

(define-syntax run*
  (syntax-rules ()
    ((run* q g ...) (run #f q g ...))))

;;
;; Compiler
;;

(begin-for-syntax
  (define compiled-names (make-free-id-table))
  
  (define (compile-goal g)
    (syntax-parse g
      #:literals (succeed fail == disj2 conj2 fresh1 project ifte once)
      [(succeed)
       #'succeed-rt]
      [(fail)
       #'fail-rt]
      [(== t1 t2)
       #`(==-rt #,(compile-term #'t1) #,(compile-term #'t2))]
      [(disj2 g1 g2)
       #`(disj2-rt #,(compile-goal #'g1) #,(compile-goal #'g2))]
      [(conj2 g1 g2)
       #`(conj2-rt #,(compile-goal #'g1) #,(compile-goal #'g2))]
      [(fresh1 (x) b)
       #:with compiled-x (compile-binder! compiled-names #'x)
       #`(call/fresh 'x (lambda (compiled-x) #,(compile-goal #'b)))]
      
      ; TODO: use `host`, allow goal-expression inside, check contract via wrapper.
      #;[(project (x ...) e:expr ...)
         #'(lambda (s)
             (let ([x (walk* x s)])
               ))]

      [(ifte g1 g2 g3)
       #`(ifte-rt #,(compile-goal #'g1) #,(compile-goal #'g2) #,(compile-goal #'g3))]
      [(once g)
       #`(once-rt #,(compile-goal #'g))]
      [(relname t ...)
       #:with compiled-relation (compile-reference compiled-names #'relname)
       #:with (compiled-term ...) (map compile-term (attribute t))
       #'(compiled-relation compiled-term ...)]))
  
  (define (compile-term t)
    (syntax-parse t
      #:literals (quote cons)
      [n:number
       #''n]
      [x:id
       (compile-reference compiled-names #'x)]
      [(quote t)
       #''t]
      [(cons t1 t2)
       #`(cons #,(compile-term #'t1) #,(compile-term #'t2))])))

;;
;; Runtime
;;

(define var (lambda (x) (vector x)))
(define var? (lambda (x) (vector? x)))

(define empty-s '())

(define (walk v s)
  (let ((a (and (var? v) (assv v s))))
    (cond
      ((pair? a) (walk (cdr a) s))
      (else v))))

(define (ext-s x v s)
  (cond
    ((occurs? x v s) #f)
    (else (cons `(,x . ,v) s))))

(define (occurs? x v s)
  (let ((v (walk v s)))
    (cond
      ((var? v) (eqv? v x))
      ((pair? v) 
       (or (occurs? x (car v) s)
           (occurs? x (cdr v) s)))
      (else #f))))

(define (unify u v s)
  (let ((u (walk u s)) (v (walk v s)))
    (cond
      ((eqv? u v) s)
      ((var? u) (ext-s u v s))
      ((var? v) (ext-s v u s))
      ((and (pair? u) (pair? v))
       (let ((s (unify (car u) (car v) s)))
         (and s
              (unify (cdr u) (cdr v) s))))
      (else #f))))

(define (==-rt u v)
  (lambda (s)
    (let ((s (unify u v s)))
      (if s `(,s) '()))))

(define succeed-rt
  (lambda (s)
    `(,s)))
 
(define fail-rt
  (lambda (s)
    '()))

(define (disj2-rt g1 g2)
  (lambda (s)
    (append-inf (g1 s) (g2 s))))

(define (append-inf s-inf t-inf)
  (cond
    ((null? s-inf) t-inf)
    ((pair? s-inf) 
     (cons (car s-inf)
           (append-inf (cdr s-inf) t-inf)))
    (else (lambda () 
            (append-inf t-inf (s-inf))))))

(define (take-inf n s-inf)
  (cond
    ((and n (zero? n)) '())
    ((null? s-inf) '())
    ((pair? s-inf) 
     (cons (car s-inf)
           (take-inf (and n (sub1 n))
                     (cdr s-inf))))
    (else (take-inf n (s-inf)))))

(define (conj2-rt g1 g2)
  (lambda (s)
    (append-map-inf g2 (g1 s))))

(define (append-map-inf g s-inf)
  (cond
    ((null? s-inf) '())
    ((pair? s-inf)
     (append-inf (g (car s-inf))
                 (append-map-inf g (cdr s-inf))))
    (else (lambda () 
            (append-map-inf g (s-inf))))))

(define (call/fresh name f)
  (f (var name)))

(define (reify-name n)
  (string->symbol
   (string-append "_"
                  (number->string n))))

(define (walk* v s)
  (let ((v (walk v s)))
    (cond
      ((var? v) v)
      ((pair? v)
       (cons
        (walk* (car v) s)
        (walk* (cdr v) s)))
      (else v))))

(define (reify-s v r)
  (let ((v (walk v r)))
    (cond
      ((var? v)
       (let ((n (length r)))
         (let ((rn (reify-name n)))
           (cons `(,v . ,rn) r))))
      ((pair? v)
       (let ((r (reify-s (car v) r)))
         (reify-s (cdr v) r)))
      (else r))))

(define (reify v)
  (lambda (s)
    (let ((v (walk* v s)))
      (let ((r (reify-s v empty-s)))
        (walk* v r)))))

(define (run-goal n g)
  (take-inf n (g empty-s)))

(define (ifte-rt g1 g2 g3)
  (lambda (s)
    (let loop ((s-inf (g1 s)))
      (cond
        ((null? s-inf) (g3 s))
        ((pair? s-inf)
         (append-map-inf g2 s-inf))
        (else (lambda ()
                (loop (s-inf))))))))

(define (once-rt g)
  (lambda (s)
    (let loop ((s-inf (g s)))
      (cond
        ((null? s-inf) '())
        ((pair? s-inf)
         (cons (car s-inf) '()))
        (else (lambda ()
                (loop (s-inf))))))))