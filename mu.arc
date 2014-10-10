; what happens when our virtual machine starts up
(= initialization-fns* (queue))
(def reset ()
  (each f (as cons initialization-fns*)
    (f)))

(mac on-init body
  `(enq (fn () ,@body)
        initialization-fns*))

(mac init-fn (name . body)
  `(enq (fn () (= (function* ',name) ',body))
        initialization-fns*))

; things that a future assembler will need separate memory for:
;   code; types; args channel
(def clear ()
  (= types* (table))
  (= memory* (table))
  (= function* (table)))
(enq clear initialization-fns*)

; persisting and checking traces for each test
(= traces* (queue))
(= trace-dir* ".traces/")
(ensure-dir trace-dir*)
(= curr-trace-file* nil)
(on-init
  (awhen curr-trace-file*
;?     (prn "reset: " it)
    (tofile (+ trace-dir* it)
      (each (label trace) (as cons traces*)
        (pr label ": " trace))))
  (= curr-trace-file* nil)
  (= traces* (queue)))

(def new-trace (filename)
;?   (prn "new-trace " filename)
  (= curr-trace-file* filename))

(= dump-trace* nil)
(def trace (label . args)
;?   (prn "trace: " dump-trace*)
  (if dump-trace* (apply prn label ": " args))
  (enq (list label (apply tostring:prn args))
       traces*))

(def check-trace-contents (msg expected-contents)
  (unless (trace-contents-match expected-contents)
    (prn "F - " msg)
    (prn "  trace contents")
    (print-trace-contents-mismatch expected-contents)))

(def trace-contents-match (expected-contents)
  (each (label msg) (as cons traces*)
    (when (and expected-contents
               (is label expected-contents.0.0)
               (posmatch expected-contents.0.1 msg))
      (pop expected-contents)))
  (no expected-contents))

(def print-trace-contents-mismatch (expected-contents)
  (each (label msg) (as cons traces*)
    (whenlet (expected-label expected-msg)  expected-contents.0
      (if (and (is label expected-label)
               (posmatch expected-msg msg))
        (do (pr "  * ")
            (pop expected-contents))
        (pr "    "))
      (pr label ": " msg)))
  (prn "  couldn't find")
  (each (expected-label expected-msg)  expected-contents
    (prn "  ! " expected-label ": " expected-msg)))

(def add-fns (fns)
  (each (name . body) fns
    (= function*.name (convert-braces body))))

; running mu
(def v (operand)  ; for value
  operand.0)

(def metadata (operand)
  cdr.operand)

(def ty (operand)
  operand.1)  ; assume type is always first bit of metadata, and it's always present

(def typeinfo (operand)
  (types* ty.operand))

(def sz (operand)
;?   (prn "sz " operand)
  (if typeinfo.operand!array
    array-len.operand
    typeinfo.operand!size))
(defextend sz (typename) (isa typename 'sym)
  (or types*.typename!size
      (err "type @typename doesn't have a size: " (tostring:pr types*.typename))))

(def addr (loc)
  (if (pos 'deref metadata.loc)
    (memory* v.loc)
    v.loc))

(def addrs (n sz)
  (accum yield
    (repeat sz
      (yield n)
      (++ n))))

(def m (loc)  ; read memory, respecting metadata
;?   (prn "m " loc " " sz.loc)
  (if (is 'literal ty.loc)
        (v loc)
      (is 1 sz.loc)
        (memory* addr.loc)
      :else
        (annotate 'record
                  (map memory* (addrs addr.loc sz.loc)))))

(def setm (loc val)  ; set memory, respecting metadata
;?   (prn "setm " loc " " val)
  (assert sz.loc)
  (if (is 1 sz.loc)
    (= (memory* addr.loc) val)
    (each (dest src) (zip (addrs addr.loc sz.loc)
                          (rep val))
      (= (memory* dest) src))))

(def array-len (operand)
;?   (prn operand)
;?   (prn (memory* 1000))
  (if typeinfo.operand!array
        (m `(,v.operand integer))
      (and typeinfo.operand!address (pos 'deref metadata.operand))
        (array-len (m operand) typeinfo.operand!elem)
      :else
        (err "can't take len of non-array @operand")))

(def array-ref-addr (operand idx)
;?   (prn "aref addr: @operand @idx")
  (assert typeinfo.operand!array)
  (assert (< -1 idx (array-len operand)))
  (withs (elem  typeinfo.operand!elem
          offset  (+ 1 (* idx sz.elem)))
    (+ v.operand offset)))

(def array-ref (operand idx)
;?   (prn "aref: @operand @idx")
  (assert typeinfo.operand!array)
  (assert (< -1 idx (array-len operand)))
;?   (prn "aref2: @operand @idx")
  (withs (elem  typeinfo.operand!elem
          offset  (+ 1 (* idx sz.elem)))
;?     (prn "aref3: @elem @v.operand @offset")
    (m `(,(+ v.operand offset) ,elem))))

; context contains the call-stack of functions that haven't yet returned

(def make-context (fn-name)
  (annotate 'context (obj call-stack (list
      (obj fn-name fn-name  pc 0  caller-arg-idx 0)))))

(defextend empty (x)  (isa x 'context)
  (no rep.x!call-stack))

(def stack (context)
  ((rep context) 'call-stack))

(mac push-stack (context op)
  `(push (obj fn-name ,op  pc 0  caller-arg-idx 0)
         ((rep ,context) 'call-stack)))

(mac pop-stack (context)
  `(pop ((rep ,context) 'call-stack)))

(def top (context)
  stack.context.0)

(def body (context (o idx 0))
  (function* stack.context.idx!fn-name))

(mac pc (context (o idx 0))  ; assignable
  `((((rep ,context) 'call-stack) ,idx) 'pc))

(mac caller-arg-idx (context (o idx 0))  ; assignable
  `((((rep ,context) 'call-stack) ,idx) 'caller-arg-idx))

(= scheduling-interval* 500)

(def parse-instr (instr)
  (iflet delim (pos '<- instr)
    (list (cut instr 0 delim)  ; oargs
          (instr (+ delim 1))  ; op
          (cut instr (+ delim 2)))  ; args
    (list nil instr.0 cdr.instr)))

(def caller-args (context)  ; not assignable
  (let (_ _ args)  (parse-instr ((body context 1) (pc context 1)))
    args))

(def caller-oargs (context)  ; not assignable
  (let (oargs _ _)  (parse-instr ((body context 1) (pc context 1)))
    oargs))

(= contexts* (queue))

(def run fn-names
  (ret result 0
    (each it fn-names
      (enq make-context.it contexts*))
    ; simple round-robin scheduler
    (while (~empty contexts*)
      (let context deq.contexts*
        (trace "schedule" top.context!fn-name)
        (let insts-run (run-for-time-slice context scheduling-interval*)
          (= result (+ result insts-run)))
        (if (~empty context)
          (enq context contexts*))))))

($:require "charterm/main.rkt")

(def run-for-time-slice (context time-slice)
;?   (prn "AAA")
  (point return
;?     (prn "BBB")
    (for ninstrs 0 (< ninstrs time-slice) (++ ninstrs)
;?       (prn "CCC " pc.context " " context " " (len body.context))
      (if (empty body.context) (err "@stack.context.0!fn-name not defined"))
      (while (>= pc.context (len body.context))
        (pop-stack context)
        (if empty.context (return ninstrs))
        (++ pc.context))
;?       (prn memory*)
      (trace "run" top.context!fn-name " " pc.context ": " (body.context pc.context))
;?       (prn "--- " top.context!fn-name " " pc.context ": " (body.context pc.context))
      (let (oarg op arg)  (parse-instr (body.context pc.context))
;?         (prn op " " arg " -> " oarg)
        (let tmp
              (case op
                ; arithmetic
                add
                  (do (trace "add" (m arg.0) " " (m arg.1))
                  (+ (m arg.0) (m arg.1))
                  )
                sub
                  (- (m arg.0) (m arg.1))
                mul
                  (* (m arg.0) (m arg.1))
                div
                  (/ (real (m arg.0)) (m arg.1))
                idiv
                  (list (trunc:/ (m arg.0) (m arg.1))
                        (mod (m arg.0) (m arg.1)))

                ; boolean
                and
                  (and (m arg.0) (m arg.1))
                or
                  (or (m arg.0) (m arg.1))
                not
                  (not (m arg.0))

                ; comparison
                eq
                  (is (m arg.0) (m arg.1))
                neq
                  (do (trace "neq" (m arg.0) " " (m arg.1))
                  (~is (m arg.0) (m arg.1))
                  )
                lt
                  (< (m arg.0) (m arg.1))
                gt
                  (> (m arg.0) (m arg.1))
                le
                  (<= (m arg.0) (m arg.1))
                ge
                  (>= (m arg.0) (m arg.1))

                ; control flow
                jmp
                  (do (= pc.context (+ 1 pc.context (v arg.0)))
;?                       (prn "jumping to " pc.context)
                      (continue))
                jif
                  (when (is t (m arg.0))
                    (= pc.context (+ 1 pc.context (v arg.1)))
;?                     (prn "jumping to " pc.context)
                    (continue))

                ; data management: scalars, arrays, records
                copy
                  (m arg.0)
                get
                  (with (base arg.0  ; integer (non-symbol) memory location including metadata
                         idx (v arg.1))  ; literal integer
;?                     (prn base ": " (memory* v.base))
                    (when typeinfo.base!address
                      (assert (pos 'deref metadata.base))
                      (= base (list (memory* v.base) typeinfo.base!elem)))
;?                     (prn "after: " base)
                    (if typeinfo.base!record
                      (do (assert (< -1 idx (len typeinfo.base!elems)))
                          (m `(,(+ v.base
                                   (apply + (map sz
                                                 (firstn idx typeinfo.base!elems))))
                               ,typeinfo.base!elems.idx)))
                      (assert nil "get on invalid type @base")))
                get-address
                  (with (base arg.0
                         idx (v arg.1))
                    (when typeinfo.base!address
                      (assert (pos 'deref metadata.base))
                      (= base (list (memory* v.base) typeinfo.base!elem)))
                    (if typeinfo.base!record
                      (do (assert (< -1 idx (len typeinfo.base!elems)))
                          (+ v.base
                             (apply + (map sz
                                           (firstn idx typeinfo.base!elems)))))
                      (assert nil "get-address on invalid type @base")))
                index
                  (with (base arg.0  ; integer (non-symbol) memory location including metadata
                         idx (m arg.1))
;?                     (prn "processing index: @base @idx")
                    (when typeinfo.base!address
                      (assert (pos 'deref metadata.base))
                      (= base (list (memory* v.base) typeinfo.base!elem)))
;?                     (prn "after maybe deref: @base @idx")
;?                     (prn Memory-in-use-until ": " memory*)
                    (if typeinfo.base!array
                      (array-ref base idx)
                      (assert nil "get on invalid type @arg.0 => @base")))
                index-address
                  (with (base arg.0
                         idx (m arg.1))
                    (when typeinfo.base!address
                      (assert (pos 'deref metadata.base))
                      (= base (list (memory* v.base) typeinfo.base!elem)))
                    (if typeinfo.base!array
                      (array-ref-addr base idx)
                      (assert nil "get-address on invalid type @arg.0 => @base")))
                new
                  (let type (v arg.0)
                    (if types*.type!array
                      (new-array type (m arg.1))
                      (new-scalar type)))
                sizeof
                  (sizeof (v arg.0))
                len
                  (let base arg.0
                    (if typeinfo.base!array
                      array-len.base
                      -1))

                ; multiprocessing
                run
                  (run (v arg.0))
                fork
                  (enq (make-context (v arg.0)) contexts*)

                ; text interaction
                cls
                  (do1 nil ($.charterm-clear-screen))
                cll
                  (do1 nil ($.charterm-clear-line))
                cursor
                  (do1 nil ($.charterm-cursor (m arg.0) (m arg.1)))
                print
                  (do1 nil ((if ($.current-charterm) $.charterm-display pr) (m arg.0)))
                getc
                  (and ($.charterm-byte-ready?) ($.charterm-read-key))
                bold-mode
                  (do1 nil ($.charterm-bold))
                non-bold-mode
                  (do1 nil ($.charterm-normal))
                console-on
                  (do1 nil (if ($.current-charterm) ($.open-charterm)))
                console-off
                  (do1 nil (if ($.current-charterm) ($.close-charterm)))

                ; user-defined functions
                arg
                  (let idx (if arg
                             arg.0
                             (do1 caller-arg-idx.context
                                (++ caller-arg-idx.context)))
;?                     (prn idx)
;?                     (prn caller-args.context)
                    (m caller-args.context.idx))
                type
                  (ty (caller-args.context arg.0))
                otype
                  (ty (caller-oargs.context arg.0))
                reply
                  (do (pop-stack context)
                      (if empty.context (return ninstrs))
                      (let (caller-oargs _ _)  (parse-instr (body.context pc.context))
                        (each (dest src)  (zip caller-oargs arg)
                          (setm dest  (m src))))
                      (++ pc.context)
                      (while (>= pc.context (len body.context))
                        (pop-stack context)
                        (if empty.context (return ninstrs))
                        (++ pc.context))
                      (continue))
                ; else try to call as a user-defined function
                  (do (if function*.op
                        (push-stack context op)
                        (err "no such op @op"))
                      (continue))
                )
              ; opcode generated some value, stored in 'tmp'
              ; copy to output args
;?               (prn "store: " tmp " " oarg)
              (if (acons tmp)
                (for i 0 (< i (min len.tmp len.oarg)) ++.i
                  (setm oarg.i tmp.i))
                (when oarg  ; must be a list
;?                   (prn oarg.0)
                  (setm oarg.0 tmp)))
              )
        (++ pc.context)))
    (return time-slice)))

(enq (fn () (= Memory-in-use-until 1000))
     initialization-fns*)
(def new-scalar (type)
  (ret result Memory-in-use-until
    (++ Memory-in-use-until sizeof.type)))

(def new-array (type size)
;?   (prn "new array: @type @size")
  (ret result Memory-in-use-until
    (++ Memory-in-use-until (+ 1 (* (sizeof types*.type!elem) size)))))

(def sizeof (type)
  (if (~or types*.type!record types*.type!array)
        types*.type!size
      types*.type!record
        (sum idfn
          (accum yield
            (each elem types*.type!elems
              (yield sizeof.elem))))))

; desugar structured assembly based on blocks

(def convert-braces (instrs)
  (let locs ()  ; list of information on each brace: (open/close pc)
    (let pc 0
      (loop (instrs instrs)
        (each instr instrs
          (if (~is 'begin instr.0)
            (do
              (trace "cvt0" pc " " instr " -- " locs)
              (++ pc))
            ; hack: racket replaces curlies with parens, so we need the
            ; keyword begin to delimit blocks.
            ; ultimately there'll be no nesting and curlies will just be in a
            ; line by themselves.
            (do
;?               (prn `(open ,pc))
              (push `(open ,pc) locs)
              (recur cdr.instr)
;?               (prn `(close ,pc))
              (push `(close ,pc) locs))))))
    (zap rev locs)
;?     (prn locs)
    (with (pc  0
           stack  ())  ; elems are pcs
      (accum yield
        (loop (instrs instrs)
          (each instr instrs
            (point continue
            (let delim (or (pos '<- instr) -1)
              (with (oarg  (if (>= delim 0)
                             (cut instr 0 delim))
                     op  (instr (+ delim 1))
                     arg  (cut instr (+ delim 2)))
                (trace "cvt1" pc " " op " " oarg)
                (case op
                  begin
                    (do
                      (push pc stack)
                      (assert:is oarg nil)
                      (recur arg)
                      (pop stack)
                      (continue))
                  break
                    (do
                      (assert:is oarg nil)
                      (assert:is arg nil)
                      (yield `(jmp (,(close-offset pc locs) offset))))
                  breakif
                    (do
;?                       (prn "breakif: " instr)
                      (assert:is oarg nil)
                      (yield `(jif ,arg.0 (,(close-offset pc locs) offset))))
                  continue
                    (do
                      (assert:is oarg nil)
                      (assert:is arg nil)
                      (yield `(jmp (,(- stack.0 pc) offset))))
                  continueif
                    (do
                      (trace "cvt0" "continueif: " instr " => " (- stack.0 1))
                      (assert:is oarg nil)
                      (yield `(jif ,arg.0 (,(- stack.0 1 pc) offset))))
                  ;else
                    (yield instr))))
            (++ pc))))))))

(def close-offset (pc locs)
  (let close 0
    (with (stacksize 0
           done nil)
      (each (state loc) locs
;?         (prn "  :" close " " state " - " loc)
        (if (< loc pc)
              nil  ; do nothing
            (no done)
              (do
                ; first time
                (when (and (is 0 stacksize) (~is loc pc))
                  (++ stacksize))
                (if (is 'open state) (++ stacksize) (-- stacksize))
                ; last time
                (when (is 0 stacksize)
                  (= close loc)
                  (set done))))))
    (- close pc 1)))

(def prn2 (msg . args)
  (pr msg)
  (apply prn args))

; after loading all files, start at 'main'
(reset)
(awhen cdr.argv
  (map add-fns:readfile it)
  ($.open-charterm)
  (run 'main)
  (if ($.current-charterm) ($.close-charterm))
  (prn memory*))
