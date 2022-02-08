#lang racket/base

(require "../../testing.rkt")

(begin-for-syntax
  (define-syntax-class string
    (pattern val #:when (string? (syntax-e #'val)))))

(define-hosted-syntaxes
  (binding-class var #:description "PEG variable")
  (binding-class nonterm #:description "PEG nonterminal")
  (extension-class peg-macro #:description "PEG macro")

  (nonterminal peg-el
    #:description "PEG expression"
    #:allow-extension peg-macro

    n:nonterm
    (eps)
    (char e:expr)
    (token e:expr)
    (alt e1:peg e2:peg)
    (not e:peg)

    (text e:expr)
    #:binding (host e)
    
    (=> ps:peg-seq e:expr)
    #:binding (nest-one ps (host e)))

  (nesting-nonterminal peg-seq (tail)
    #:description "PEG expression"
    #:allow-extension peg-macro
    
    (bind v:var ps:peg-seq)
    #:binding {(bind v) (nest-one ps tail)}
    
    (seq ps1:peg-seq ps2:peg-seq)
    #:binding (nest-one ps1 (nest-one ps2 tail))

    (repeat ps:peg-seq)
    #:binding (nest-one ps tail)

    (src-span v:var ps:peg-seq)
    #:binding {(bind v) (nest-one ps tail)}

    pe:peg-el)

  (nonterminal peg   
    ps:peg-seq
    #:binding (nest-one ps [])))

(require racket/match)

(define v (expand-nonterminal/datum peg
            (=> (seq (bind a (text "a")) (bind b (=> (bind c (text "b"))
                                                     (list a c))))
                (list a b))))

(check-true
 (match v
   [`(=> (seq (bind a (text ,_)) (bind b (=> (bind c (text ,_))
                                             ,_)))
         ,_)
    #t]))