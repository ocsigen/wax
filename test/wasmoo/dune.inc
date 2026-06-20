(subdir wasm-formatted
 (rule
  (target array.wat.gen)
  (deps ../wasm-source/array.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/array.wat)))
 (rule
  (alias runtest)
  (action
   (diff array.wat array.wat.gen))))

(subdir wax
 (rule
  (target array.wax.gen)
  (deps ../wasm-source/array.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/array.wat)))
 (rule
  (alias runtest)
  (action
   (diff array.wax array.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target array.wat.gen)
  (deps ../wax/array.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/array.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff array.wat array.wat.gen))))

(subdir wat-idempotent
 (rule
  (target array.wat.gen)
  (deps ../wasm-formatted/array.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/array.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/array.wat.gen array.wat.gen))))

(subdir wax-idempotent
 (rule
  (target array.wax.gen)
  (deps ../wax/array.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/array.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/array.wax.gen array.wax.gen))))

(subdir wax-round-trip
 (rule
  (target array.wax.gen)
  (deps ../wasm-round-trip/array.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/array.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/array.wax array.wax.gen))))

(subdir wasm-formatted
 (rule
  (target backtrace.wat.gen)
  (deps ../wasm-source/backtrace.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/backtrace.wat)))
 (rule
  (alias runtest)
  (action
   (diff backtrace.wat backtrace.wat.gen))))

(subdir wax
 (rule
  (target backtrace.wax.gen)
  (deps ../wasm-source/backtrace.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/backtrace.wat)))
 (rule
  (alias runtest)
  (action
   (diff backtrace.wax backtrace.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target backtrace.wat.gen)
  (deps ../wax/backtrace.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/backtrace.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff backtrace.wat backtrace.wat.gen))))

(subdir wat-idempotent
 (rule
  (target backtrace.wat.gen)
  (deps ../wasm-formatted/backtrace.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/backtrace.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/backtrace.wat.gen backtrace.wat.gen))))

(subdir wax-idempotent
 (rule
  (target backtrace.wax.gen)
  (deps ../wax/backtrace.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/backtrace.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/backtrace.wax.gen backtrace.wax.gen))))

(subdir wax-round-trip
 (rule
  (target backtrace.wax.gen)
  (deps ../wasm-round-trip/backtrace.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/backtrace.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/backtrace.wax backtrace.wax.gen))))

(subdir wasm-formatted
 (rule
  (target bigarray.wat.gen)
  (deps ../wasm-source/bigarray.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/bigarray.wat)))
 (rule
  (alias runtest)
  (action
   (diff bigarray.wat bigarray.wat.gen))))

(subdir wax
 (rule
  (target bigarray.wax.gen)
  (deps ../wasm-source/bigarray.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/bigarray.wat)))
 (rule
  (alias runtest)
  (action
   (diff bigarray.wax bigarray.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target bigarray.wat.gen)
  (deps ../wax/bigarray.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/bigarray.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff bigarray.wat bigarray.wat.gen))))

(subdir wat-idempotent
 (rule
  (target bigarray.wat.gen)
  (deps ../wasm-formatted/bigarray.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/bigarray.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/bigarray.wat.gen bigarray.wat.gen))))

(subdir wax-idempotent
 (rule
  (target bigarray.wax.gen)
  (deps ../wax/bigarray.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/bigarray.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/bigarray.wax.gen bigarray.wax.gen))))

(subdir wax-round-trip
 (rule
  (target bigarray.wax.gen)
  (deps ../wasm-round-trip/bigarray.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/bigarray.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/bigarray.wax bigarray.wax.gen))))

(subdir wasm-formatted
 (rule
  (target bigstring.wat.gen)
  (deps ../wasm-source/bigstring.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/bigstring.wat)))
 (rule
  (alias runtest)
  (action
   (diff bigstring.wat bigstring.wat.gen))))

(subdir wax
 (rule
  (target bigstring.wax.gen)
  (deps ../wasm-source/bigstring.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/bigstring.wat)))
 (rule
  (alias runtest)
  (action
   (diff bigstring.wax bigstring.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target bigstring.wat.gen)
  (deps ../wax/bigstring.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/bigstring.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff bigstring.wat bigstring.wat.gen))))

(subdir wat-idempotent
 (rule
  (target bigstring.wat.gen)
  (deps ../wasm-formatted/bigstring.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/bigstring.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/bigstring.wat.gen bigstring.wat.gen))))

(subdir wax-idempotent
 (rule
  (target bigstring.wax.gen)
  (deps ../wax/bigstring.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/bigstring.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/bigstring.wax.gen bigstring.wax.gen))))

(subdir wax-round-trip
 (rule
  (target bigstring.wax.gen)
  (deps ../wasm-round-trip/bigstring.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/bigstring.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/bigstring.wax bigstring.wax.gen))))

(subdir wasm-formatted
 (rule
  (target compare.wat.gen)
  (deps ../wasm-source/compare.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/compare.wat)))
 (rule
  (alias runtest)
  (action
   (diff compare.wat compare.wat.gen))))

(subdir wax
 (rule
  (target compare.wax.gen)
  (deps ../wasm-source/compare.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/compare.wat)))
 (rule
  (alias runtest)
  (action
   (diff compare.wax compare.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target compare.wat.gen)
  (deps ../wax/compare.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/compare.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff compare.wat compare.wat.gen))))

(subdir wat-idempotent
 (rule
  (target compare.wat.gen)
  (deps ../wasm-formatted/compare.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/compare.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/compare.wat.gen compare.wat.gen))))

(subdir wax-idempotent
 (rule
  (target compare.wax.gen)
  (deps ../wax/compare.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/compare.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/compare.wax.gen compare.wax.gen))))

(subdir wax-round-trip
 (rule
  (target compare.wax.gen)
  (deps ../wasm-round-trip/compare.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/compare.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/compare.wax compare.wax.gen))))

(subdir wasm-formatted
 (rule
  (target custom.wat.gen)
  (deps ../wasm-source/custom.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/custom.wat)))
 (rule
  (alias runtest)
  (action
   (diff custom.wat custom.wat.gen))))

(subdir wax
 (rule
  (target custom.wax.gen)
  (deps ../wasm-source/custom.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/custom.wat)))
 (rule
  (alias runtest)
  (action
   (diff custom.wax custom.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target custom.wat.gen)
  (deps ../wax/custom.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/custom.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff custom.wat custom.wat.gen))))

(subdir wat-idempotent
 (rule
  (target custom.wat.gen)
  (deps ../wasm-formatted/custom.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/custom.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/custom.wat.gen custom.wat.gen))))

(subdir wax-idempotent
 (rule
  (target custom.wax.gen)
  (deps ../wax/custom.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/custom.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/custom.wax.gen custom.wax.gen))))

(subdir wax-round-trip
 (rule
  (target custom.wax.gen)
  (deps ../wasm-round-trip/custom.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/custom.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/custom.wax custom.wax.gen))))

(subdir wasm-formatted
 (rule
  (target domain.wat.gen)
  (deps ../wasm-source/domain.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/domain.wat)))
 (rule
  (alias runtest)
  (action
   (diff domain.wat domain.wat.gen))))

(subdir wax
 (rule
  (target domain.wax.gen)
  (deps ../wasm-source/domain.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/domain.wat)))
 (rule
  (alias runtest)
  (action
   (diff domain.wax domain.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target domain.wat.gen)
  (deps ../wax/domain.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/domain.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff domain.wat domain.wat.gen))))

(subdir wat-idempotent
 (rule
  (target domain.wat.gen)
  (deps ../wasm-formatted/domain.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/domain.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/domain.wat.gen domain.wat.gen))))

(subdir wax-idempotent
 (rule
  (target domain.wax.gen)
  (deps ../wax/domain.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/domain.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/domain.wax.gen domain.wax.gen))))

(subdir wax-round-trip
 (rule
  (target domain.wax.gen)
  (deps ../wasm-round-trip/domain.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/domain.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/domain.wax domain.wax.gen))))

(subdir wasm-formatted
 (rule
  (target dynlink.wat.gen)
  (deps ../wasm-source/dynlink.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/dynlink.wat)))
 (rule
  (alias runtest)
  (action
   (diff dynlink.wat dynlink.wat.gen))))

(subdir wax
 (rule
  (target dynlink.wax.gen)
  (deps ../wasm-source/dynlink.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/dynlink.wat)))
 (rule
  (alias runtest)
  (action
   (diff dynlink.wax dynlink.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target dynlink.wat.gen)
  (deps ../wax/dynlink.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/dynlink.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff dynlink.wat dynlink.wat.gen))))

(subdir wat-idempotent
 (rule
  (target dynlink.wat.gen)
  (deps ../wasm-formatted/dynlink.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/dynlink.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/dynlink.wat.gen dynlink.wat.gen))))

(subdir wax-idempotent
 (rule
  (target dynlink.wax.gen)
  (deps ../wax/dynlink.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/dynlink.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/dynlink.wax.gen dynlink.wax.gen))))

(subdir wax-round-trip
 (rule
  (target dynlink.wax.gen)
  (deps ../wasm-round-trip/dynlink.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/dynlink.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/dynlink.wax dynlink.wax.gen))))

(subdir wasm-formatted
 (rule
  (target effect.wat.gen)
  (deps ../wasm-source/effect.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/effect.wat)))
 (rule
  (alias runtest)
  (action
   (diff effect.wat effect.wat.gen))))

(subdir wax
 (rule
  (target effect.wax.gen)
  (deps ../wasm-source/effect.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/effect.wat)))
 (rule
  (alias runtest)
  (action
   (diff effect.wax effect.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target effect.wat.gen)
  (deps ../wax/effect.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/effect.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff effect.wat effect.wat.gen))))

(subdir wat-idempotent
 (rule
  (target effect.wat.gen)
  (deps ../wasm-formatted/effect.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/effect.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/effect.wat.gen effect.wat.gen))))

(subdir wax-idempotent
 (rule
  (target effect.wax.gen)
  (deps ../wax/effect.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/effect.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/effect.wax.gen effect.wax.gen))))

(subdir wax-round-trip
 (rule
  (target effect.wax.gen)
  (deps ../wasm-round-trip/effect.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/effect.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/effect.wax effect.wax.gen))))

(subdir wasm-formatted
 (rule
  (target fail.wat.gen)
  (deps ../wasm-source/fail.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/fail.wat)))
 (rule
  (alias runtest)
  (action
   (diff fail.wat fail.wat.gen))))

(subdir wax
 (rule
  (target fail.wax.gen)
  (deps ../wasm-source/fail.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/fail.wat)))
 (rule
  (alias runtest)
  (action
   (diff fail.wax fail.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target fail.wat.gen)
  (deps ../wax/fail.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/fail.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff fail.wat fail.wat.gen))))

(subdir wat-idempotent
 (rule
  (target fail.wat.gen)
  (deps ../wasm-formatted/fail.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/fail.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/fail.wat.gen fail.wat.gen))))

(subdir wax-idempotent
 (rule
  (target fail.wax.gen)
  (deps ../wax/fail.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/fail.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/fail.wax.gen fail.wax.gen))))

(subdir wax-round-trip
 (rule
  (target fail.wax.gen)
  (deps ../wasm-round-trip/fail.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/fail.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/fail.wax fail.wax.gen))))

(subdir wasm-formatted
 (rule
  (target float.wat.gen)
  (deps ../wasm-source/float.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/float.wat)))
 (rule
  (alias runtest)
  (action
   (diff float.wat float.wat.gen))))

(subdir wax
 (rule
  (target float.wax.gen)
  (deps ../wasm-source/float.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/float.wat)))
 (rule
  (alias runtest)
  (action
   (diff float.wax float.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target float.wat.gen)
  (deps ../wax/float.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/float.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff float.wat float.wat.gen))))

(subdir wat-idempotent
 (rule
  (target float.wat.gen)
  (deps ../wasm-formatted/float.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/float.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/float.wat.gen float.wat.gen))))

(subdir wax-idempotent
 (rule
  (target float.wax.gen)
  (deps ../wax/float.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/float.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/float.wax.gen float.wax.gen))))

(subdir wax-round-trip
 (rule
  (target float.wax.gen)
  (deps ../wasm-round-trip/float.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/float.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/float.wax float.wax.gen))))

(subdir wasm-formatted
 (rule
  (target fs.wat.gen)
  (deps ../wasm-source/fs.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/fs.wat)))
 (rule
  (alias runtest)
  (action
   (diff fs.wat fs.wat.gen))))

(subdir wax
 (rule
  (target fs.wax.gen)
  (deps ../wasm-source/fs.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/fs.wat)))
 (rule
  (alias runtest)
  (action
   (diff fs.wax fs.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target fs.wat.gen)
  (deps ../wax/fs.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/fs.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff fs.wat fs.wat.gen))))

(subdir wat-idempotent
 (rule
  (target fs.wat.gen)
  (deps ../wasm-formatted/fs.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/fs.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/fs.wat.gen fs.wat.gen))))

(subdir wax-idempotent
 (rule
  (target fs.wax.gen)
  (deps ../wax/fs.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/fs.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/fs.wax.gen fs.wax.gen))))

(subdir wax-round-trip
 (rule
  (target fs.wax.gen)
  (deps ../wasm-round-trip/fs.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/fs.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/fs.wax fs.wax.gen))))

(subdir wasm-formatted
 (rule
  (target gc.wat.gen)
  (deps ../wasm-source/gc.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/gc.wat)))
 (rule
  (alias runtest)
  (action
   (diff gc.wat gc.wat.gen))))

(subdir wax
 (rule
  (target gc.wax.gen)
  (deps ../wasm-source/gc.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/gc.wat)))
 (rule
  (alias runtest)
  (action
   (diff gc.wax gc.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target gc.wat.gen)
  (deps ../wax/gc.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/gc.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff gc.wat gc.wat.gen))))

(subdir wat-idempotent
 (rule
  (target gc.wat.gen)
  (deps ../wasm-formatted/gc.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/gc.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/gc.wat.gen gc.wat.gen))))

(subdir wax-idempotent
 (rule
  (target gc.wax.gen)
  (deps ../wax/gc.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/gc.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/gc.wax.gen gc.wax.gen))))

(subdir wax-round-trip
 (rule
  (target gc.wax.gen)
  (deps ../wasm-round-trip/gc.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/gc.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/gc.wax gc.wax.gen))))

(subdir wasm-formatted
 (rule
  (target hash.wat.gen)
  (deps ../wasm-source/hash.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/hash.wat)))
 (rule
  (alias runtest)
  (action
   (diff hash.wat hash.wat.gen))))

(subdir wax
 (rule
  (target hash.wax.gen)
  (deps ../wasm-source/hash.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/hash.wat)))
 (rule
  (alias runtest)
  (action
   (diff hash.wax hash.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target hash.wat.gen)
  (deps ../wax/hash.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/hash.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff hash.wat hash.wat.gen))))

(subdir wat-idempotent
 (rule
  (target hash.wat.gen)
  (deps ../wasm-formatted/hash.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/hash.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/hash.wat.gen hash.wat.gen))))

(subdir wax-idempotent
 (rule
  (target hash.wax.gen)
  (deps ../wax/hash.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/hash.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/hash.wax.gen hash.wax.gen))))

(subdir wax-round-trip
 (rule
  (target hash.wax.gen)
  (deps ../wasm-round-trip/hash.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/hash.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/hash.wax hash.wax.gen))))

(subdir wasm-formatted
 (rule
  (target int32.wat.gen)
  (deps ../wasm-source/int32.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/int32.wat)))
 (rule
  (alias runtest)
  (action
   (diff int32.wat int32.wat.gen))))

(subdir wax
 (rule
  (target int32.wax.gen)
  (deps ../wasm-source/int32.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/int32.wat)))
 (rule
  (alias runtest)
  (action
   (diff int32.wax int32.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target int32.wat.gen)
  (deps ../wax/int32.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/int32.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff int32.wat int32.wat.gen))))

(subdir wat-idempotent
 (rule
  (target int32.wat.gen)
  (deps ../wasm-formatted/int32.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/int32.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/int32.wat.gen int32.wat.gen))))

(subdir wax-idempotent
 (rule
  (target int32.wax.gen)
  (deps ../wax/int32.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/int32.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/int32.wax.gen int32.wax.gen))))

(subdir wax-round-trip
 (rule
  (target int32.wax.gen)
  (deps ../wasm-round-trip/int32.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/int32.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/int32.wax int32.wax.gen))))

(subdir wasm-formatted
 (rule
  (target int64.wat.gen)
  (deps ../wasm-source/int64.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/int64.wat)))
 (rule
  (alias runtest)
  (action
   (diff int64.wat int64.wat.gen))))

(subdir wax
 (rule
  (target int64.wax.gen)
  (deps ../wasm-source/int64.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/int64.wat)))
 (rule
  (alias runtest)
  (action
   (diff int64.wax int64.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target int64.wat.gen)
  (deps ../wax/int64.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/int64.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff int64.wat int64.wat.gen))))

(subdir wat-idempotent
 (rule
  (target int64.wat.gen)
  (deps ../wasm-formatted/int64.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/int64.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/int64.wat.gen int64.wat.gen))))

(subdir wax-idempotent
 (rule
  (target int64.wax.gen)
  (deps ../wax/int64.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/int64.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/int64.wax.gen int64.wax.gen))))

(subdir wax-round-trip
 (rule
  (target int64.wax.gen)
  (deps ../wasm-round-trip/int64.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/int64.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/int64.wax int64.wax.gen))))

(subdir wasm-formatted
 (rule
  (target ints.wat.gen)
  (deps ../wasm-source/ints.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/ints.wat)))
 (rule
  (alias runtest)
  (action
   (diff ints.wat ints.wat.gen))))

(subdir wax
 (rule
  (target ints.wax.gen)
  (deps ../wasm-source/ints.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/ints.wat)))
 (rule
  (alias runtest)
  (action
   (diff ints.wax ints.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target ints.wat.gen)
  (deps ../wax/ints.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/ints.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ints.wat ints.wat.gen))))

(subdir wat-idempotent
 (rule
  (target ints.wat.gen)
  (deps ../wasm-formatted/ints.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/ints.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/ints.wat.gen ints.wat.gen))))

(subdir wax-idempotent
 (rule
  (target ints.wax.gen)
  (deps ../wax/ints.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/ints.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/ints.wax.gen ints.wax.gen))))

(subdir wax-round-trip
 (rule
  (target ints.wax.gen)
  (deps ../wasm-round-trip/ints.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/ints.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/ints.wax ints.wax.gen))))

(subdir wasm-formatted
 (rule
  (target io.wat.gen)
  (deps ../wasm-source/io.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/io.wat)))
 (rule
  (alias runtest)
  (action
   (diff io.wat io.wat.gen))))

(subdir wax
 (rule
  (target io.wax.gen)
  (deps ../wasm-source/io.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/io.wat)))
 (rule
  (alias runtest)
  (action
   (diff io.wax io.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target io.wat.gen)
  (deps ../wax/io.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/io.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff io.wat io.wat.gen))))

(subdir wat-idempotent
 (rule
  (target io.wat.gen)
  (deps ../wasm-formatted/io.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/io.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/io.wat.gen io.wat.gen))))

(subdir wax-idempotent
 (rule
  (target io.wax.gen)
  (deps ../wax/io.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/io.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/io.wax.gen io.wax.gen))))

(subdir wax-round-trip
 (rule
  (target io.wax.gen)
  (deps ../wasm-round-trip/io.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/io.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/io.wax io.wax.gen))))

(subdir wasm-formatted
 (rule
  (target jslib.wat.gen)
  (deps ../wasm-source/jslib.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/jslib.wat)))
 (rule
  (alias runtest)
  (action
   (diff jslib.wat jslib.wat.gen))))

(subdir wax
 (rule
  (target jslib.wax.gen)
  (deps ../wasm-source/jslib.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/jslib.wat)))
 (rule
  (alias runtest)
  (action
   (diff jslib.wax jslib.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target jslib.wat.gen)
  (deps ../wax/jslib.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/jslib.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff jslib.wat jslib.wat.gen))))

(subdir wat-idempotent
 (rule
  (target jslib.wat.gen)
  (deps ../wasm-formatted/jslib.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/jslib.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/jslib.wat.gen jslib.wat.gen))))

(subdir wax-idempotent
 (rule
  (target jslib.wax.gen)
  (deps ../wax/jslib.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/jslib.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/jslib.wax.gen jslib.wax.gen))))

(subdir wax-round-trip
 (rule
  (target jslib.wax.gen)
  (deps ../wasm-round-trip/jslib.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/jslib.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/jslib.wax jslib.wax.gen))))

(subdir wasm-formatted
 (rule
  (target jslib_js_of_ocaml.wat.gen)
  (deps ../wasm-source/jslib_js_of_ocaml.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/jslib_js_of_ocaml.wat)))
 (rule
  (alias runtest)
  (action
   (diff jslib_js_of_ocaml.wat jslib_js_of_ocaml.wat.gen))))

(subdir wax
 (rule
  (target jslib_js_of_ocaml.wax.gen)
  (deps ../wasm-source/jslib_js_of_ocaml.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/jslib_js_of_ocaml.wat)))
 (rule
  (alias runtest)
  (action
   (diff jslib_js_of_ocaml.wax jslib_js_of_ocaml.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target jslib_js_of_ocaml.wat.gen)
  (deps ../wax/jslib_js_of_ocaml.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/jslib_js_of_ocaml.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff jslib_js_of_ocaml.wat jslib_js_of_ocaml.wat.gen))))

(subdir wat-idempotent
 (rule
  (target jslib_js_of_ocaml.wat.gen)
  (deps ../wasm-formatted/jslib_js_of_ocaml.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/jslib_js_of_ocaml.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/jslib_js_of_ocaml.wat.gen jslib_js_of_ocaml.wat.gen))))

(subdir wax-idempotent
 (rule
  (target jslib_js_of_ocaml.wax.gen)
  (deps ../wax/jslib_js_of_ocaml.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/jslib_js_of_ocaml.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/jslib_js_of_ocaml.wax.gen jslib_js_of_ocaml.wax.gen))))

(subdir wax-round-trip
 (rule
  (target jslib_js_of_ocaml.wax.gen)
  (deps ../wasm-round-trip/jslib_js_of_ocaml.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/jslib_js_of_ocaml.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/jslib_js_of_ocaml.wax jslib_js_of_ocaml.wax.gen))))

(subdir wasm-formatted
 (rule
  (target jsstring.wat.gen)
  (deps ../wasm-source/jsstring.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/jsstring.wat)))
 (rule
  (alias runtest)
  (action
   (diff jsstring.wat jsstring.wat.gen))))

(subdir wax
 (rule
  (target jsstring.wax.gen)
  (deps ../wasm-source/jsstring.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/jsstring.wat)))
 (rule
  (alias runtest)
  (action
   (diff jsstring.wax jsstring.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target jsstring.wat.gen)
  (deps ../wax/jsstring.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/jsstring.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff jsstring.wat jsstring.wat.gen))))

(subdir wat-idempotent
 (rule
  (target jsstring.wat.gen)
  (deps ../wasm-formatted/jsstring.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/jsstring.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/jsstring.wat.gen jsstring.wat.gen))))

(subdir wax-idempotent
 (rule
  (target jsstring.wax.gen)
  (deps ../wax/jsstring.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/jsstring.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/jsstring.wax.gen jsstring.wax.gen))))

(subdir wax-round-trip
 (rule
  (target jsstring.wax.gen)
  (deps ../wasm-round-trip/jsstring.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/jsstring.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/jsstring.wax jsstring.wax.gen))))

(subdir wasm-formatted
 (rule
  (target lexing.wat.gen)
  (deps ../wasm-source/lexing.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/lexing.wat)))
 (rule
  (alias runtest)
  (action
   (diff lexing.wat lexing.wat.gen))))

(subdir wax
 (rule
  (target lexing.wax.gen)
  (deps ../wasm-source/lexing.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/lexing.wat)))
 (rule
  (alias runtest)
  (action
   (diff lexing.wax lexing.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target lexing.wat.gen)
  (deps ../wax/lexing.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/lexing.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff lexing.wat lexing.wat.gen))))

(subdir wat-idempotent
 (rule
  (target lexing.wat.gen)
  (deps ../wasm-formatted/lexing.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/lexing.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/lexing.wat.gen lexing.wat.gen))))

(subdir wax-idempotent
 (rule
  (target lexing.wax.gen)
  (deps ../wax/lexing.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/lexing.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/lexing.wax.gen lexing.wax.gen))))

(subdir wax-round-trip
 (rule
  (target lexing.wax.gen)
  (deps ../wasm-round-trip/lexing.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/lexing.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/lexing.wax lexing.wax.gen))))

(subdir wasm-formatted
 (rule
  (target marshal.wat.gen)
  (deps ../wasm-source/marshal.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/marshal.wat)))
 (rule
  (alias runtest)
  (action
   (diff marshal.wat marshal.wat.gen))))

(subdir wax
 (rule
  (target marshal.wax.gen)
  (deps ../wasm-source/marshal.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/marshal.wat)))
 (rule
  (alias runtest)
  (action
   (diff marshal.wax marshal.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target marshal.wat.gen)
  (deps ../wax/marshal.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/marshal.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff marshal.wat marshal.wat.gen))))

(subdir wat-idempotent
 (rule
  (target marshal.wat.gen)
  (deps ../wasm-formatted/marshal.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/marshal.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/marshal.wat.gen marshal.wat.gen))))

(subdir wax-idempotent
 (rule
  (target marshal.wax.gen)
  (deps ../wax/marshal.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/marshal.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/marshal.wax.gen marshal.wax.gen))))

(subdir wax-round-trip
 (rule
  (target marshal.wax.gen)
  (deps ../wasm-round-trip/marshal.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/marshal.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/marshal.wax marshal.wax.gen))))

(subdir wasm-formatted
 (rule
  (target md5.wat.gen)
  (deps ../wasm-source/md5.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/md5.wat)))
 (rule
  (alias runtest)
  (action
   (diff md5.wat md5.wat.gen))))

(subdir wax
 (rule
  (target md5.wax.gen)
  (deps ../wasm-source/md5.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/md5.wat)))
 (rule
  (alias runtest)
  (action
   (diff md5.wax md5.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target md5.wat.gen)
  (deps ../wax/md5.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/md5.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff md5.wat md5.wat.gen))))

(subdir wat-idempotent
 (rule
  (target md5.wat.gen)
  (deps ../wasm-formatted/md5.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/md5.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/md5.wat.gen md5.wat.gen))))

(subdir wax-idempotent
 (rule
  (target md5.wax.gen)
  (deps ../wax/md5.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/md5.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/md5.wax.gen md5.wax.gen))))

(subdir wax-round-trip
 (rule
  (target md5.wax.gen)
  (deps ../wasm-round-trip/md5.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/md5.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/md5.wax md5.wax.gen))))

(subdir wasm-formatted
 (rule
  (target nat.wat.gen)
  (deps ../wasm-source/nat.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/nat.wat)))
 (rule
  (alias runtest)
  (action
   (diff nat.wat nat.wat.gen))))

(subdir wax
 (rule
  (target nat.wax.gen)
  (deps ../wasm-source/nat.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/nat.wat)))
 (rule
  (alias runtest)
  (action
   (diff nat.wax nat.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target nat.wat.gen)
  (deps ../wax/nat.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/nat.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff nat.wat nat.wat.gen))))

(subdir wat-idempotent
 (rule
  (target nat.wat.gen)
  (deps ../wasm-formatted/nat.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/nat.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/nat.wat.gen nat.wat.gen))))

(subdir wax-idempotent
 (rule
  (target nat.wax.gen)
  (deps ../wax/nat.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/nat.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/nat.wax.gen nat.wax.gen))))

(subdir wax-round-trip
 (rule
  (target nat.wax.gen)
  (deps ../wasm-round-trip/nat.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/nat.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/nat.wax nat.wax.gen))))

(subdir wasm-formatted
 (rule
  (target obj.wat.gen)
  (deps ../wasm-source/obj.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/obj.wat)))
 (rule
  (alias runtest)
  (action
   (diff obj.wat obj.wat.gen))))

(subdir wax
 (rule
  (target obj.wax.gen)
  (deps ../wasm-source/obj.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/obj.wat)))
 (rule
  (alias runtest)
  (action
   (diff obj.wax obj.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target obj.wat.gen)
  (deps ../wax/obj.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/obj.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff obj.wat obj.wat.gen))))

(subdir wat-idempotent
 (rule
  (target obj.wat.gen)
  (deps ../wasm-formatted/obj.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/obj.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/obj.wat.gen obj.wat.gen))))

(subdir wax-idempotent
 (rule
  (target obj.wax.gen)
  (deps ../wax/obj.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/obj.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/obj.wax.gen obj.wax.gen))))

(subdir wax-round-trip
 (rule
  (target obj.wax.gen)
  (deps ../wasm-round-trip/obj.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/obj.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/obj.wax obj.wax.gen))))

(subdir wasm-formatted
 (rule
  (target parsing.wat.gen)
  (deps ../wasm-source/parsing.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/parsing.wat)))
 (rule
  (alias runtest)
  (action
   (diff parsing.wat parsing.wat.gen))))

(subdir wax
 (rule
  (target parsing.wax.gen)
  (deps ../wasm-source/parsing.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/parsing.wat)))
 (rule
  (alias runtest)
  (action
   (diff parsing.wax parsing.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target parsing.wat.gen)
  (deps ../wax/parsing.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/parsing.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff parsing.wat parsing.wat.gen))))

(subdir wat-idempotent
 (rule
  (target parsing.wat.gen)
  (deps ../wasm-formatted/parsing.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/parsing.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/parsing.wat.gen parsing.wat.gen))))

(subdir wax-idempotent
 (rule
  (target parsing.wax.gen)
  (deps ../wax/parsing.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/parsing.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/parsing.wax.gen parsing.wax.gen))))

(subdir wax-round-trip
 (rule
  (target parsing.wax.gen)
  (deps ../wasm-round-trip/parsing.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/parsing.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/parsing.wax parsing.wax.gen))))

(subdir wasm-formatted
 (rule
  (target printexc.wat.gen)
  (deps ../wasm-source/printexc.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/printexc.wat)))
 (rule
  (alias runtest)
  (action
   (diff printexc.wat printexc.wat.gen))))

(subdir wax
 (rule
  (target printexc.wax.gen)
  (deps ../wasm-source/printexc.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/printexc.wat)))
 (rule
  (alias runtest)
  (action
   (diff printexc.wax printexc.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target printexc.wat.gen)
  (deps ../wax/printexc.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/printexc.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff printexc.wat printexc.wat.gen))))

(subdir wat-idempotent
 (rule
  (target printexc.wat.gen)
  (deps ../wasm-formatted/printexc.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/printexc.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/printexc.wat.gen printexc.wat.gen))))

(subdir wax-idempotent
 (rule
  (target printexc.wax.gen)
  (deps ../wax/printexc.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/printexc.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/printexc.wax.gen printexc.wax.gen))))

(subdir wax-round-trip
 (rule
  (target printexc.wax.gen)
  (deps ../wasm-round-trip/printexc.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/printexc.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/printexc.wax printexc.wax.gen))))

(subdir wasm-formatted
 (rule
  (target prng.wat.gen)
  (deps ../wasm-source/prng.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/prng.wat)))
 (rule
  (alias runtest)
  (action
   (diff prng.wat prng.wat.gen))))

(subdir wax
 (rule
  (target prng.wax.gen)
  (deps ../wasm-source/prng.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/prng.wat)))
 (rule
  (alias runtest)
  (action
   (diff prng.wax prng.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target prng.wat.gen)
  (deps ../wax/prng.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/prng.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff prng.wat prng.wat.gen))))

(subdir wat-idempotent
 (rule
  (target prng.wat.gen)
  (deps ../wasm-formatted/prng.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/prng.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/prng.wat.gen prng.wat.gen))))

(subdir wax-idempotent
 (rule
  (target prng.wax.gen)
  (deps ../wax/prng.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/prng.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/prng.wax.gen prng.wax.gen))))

(subdir wax-round-trip
 (rule
  (target prng.wax.gen)
  (deps ../wasm-round-trip/prng.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/prng.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/prng.wax prng.wax.gen))))

(subdir wasm-formatted
 (rule
  (target runtime_events.wat.gen)
  (deps ../wasm-source/runtime_events.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/runtime_events.wat)))
 (rule
  (alias runtest)
  (action
   (diff runtime_events.wat runtime_events.wat.gen))))

(subdir wax
 (rule
  (target runtime_events.wax.gen)
  (deps ../wasm-source/runtime_events.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/runtime_events.wat)))
 (rule
  (alias runtest)
  (action
   (diff runtime_events.wax runtime_events.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target runtime_events.wat.gen)
  (deps ../wax/runtime_events.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/runtime_events.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff runtime_events.wat runtime_events.wat.gen))))

(subdir wat-idempotent
 (rule
  (target runtime_events.wat.gen)
  (deps ../wasm-formatted/runtime_events.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/runtime_events.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/runtime_events.wat.gen runtime_events.wat.gen))))

(subdir wax-idempotent
 (rule
  (target runtime_events.wax.gen)
  (deps ../wax/runtime_events.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/runtime_events.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/runtime_events.wax.gen runtime_events.wax.gen))))

(subdir wax-round-trip
 (rule
  (target runtime_events.wax.gen)
  (deps ../wasm-round-trip/runtime_events.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/runtime_events.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/runtime_events.wax runtime_events.wax.gen))))

(subdir wasm-formatted
 (rule
  (target stdlib.wat.gen)
  (deps ../wasm-source/stdlib.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/stdlib.wat)))
 (rule
  (alias runtest)
  (action
   (diff stdlib.wat stdlib.wat.gen))))

(subdir wax
 (rule
  (target stdlib.wax.gen)
  (deps ../wasm-source/stdlib.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/stdlib.wat)))
 (rule
  (alias runtest)
  (action
   (diff stdlib.wax stdlib.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target stdlib.wat.gen)
  (deps ../wax/stdlib.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/stdlib.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff stdlib.wat stdlib.wat.gen))))

(subdir wat-idempotent
 (rule
  (target stdlib.wat.gen)
  (deps ../wasm-formatted/stdlib.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/stdlib.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/stdlib.wat.gen stdlib.wat.gen))))

(subdir wax-idempotent
 (rule
  (target stdlib.wax.gen)
  (deps ../wax/stdlib.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/stdlib.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/stdlib.wax.gen stdlib.wax.gen))))

(subdir wax-round-trip
 (rule
  (target stdlib.wax.gen)
  (deps ../wasm-round-trip/stdlib.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/stdlib.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/stdlib.wax stdlib.wax.gen))))

(subdir wasm-formatted
 (rule
  (target str.wat.gen)
  (deps ../wasm-source/str.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/str.wat)))
 (rule
  (alias runtest)
  (action
   (diff str.wat str.wat.gen))))

(subdir wax
 (rule
  (target str.wax.gen)
  (deps ../wasm-source/str.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/str.wat)))
 (rule
  (alias runtest)
  (action
   (diff str.wax str.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target str.wat.gen)
  (deps ../wax/str.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/str.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff str.wat str.wat.gen))))

(subdir wat-idempotent
 (rule
  (target str.wat.gen)
  (deps ../wasm-formatted/str.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/str.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/str.wat.gen str.wat.gen))))

(subdir wax-idempotent
 (rule
  (target str.wax.gen)
  (deps ../wax/str.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/str.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/str.wax.gen str.wax.gen))))

(subdir wax-round-trip
 (rule
  (target str.wax.gen)
  (deps ../wasm-round-trip/str.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/str.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/str.wax str.wax.gen))))

(subdir wasm-formatted
 (rule
  (target string.wat.gen)
  (deps ../wasm-source/string.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/string.wat)))
 (rule
  (alias runtest)
  (action
   (diff string.wat string.wat.gen))))

(subdir wax
 (rule
  (target string.wax.gen)
  (deps ../wasm-source/string.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/string.wat)))
 (rule
  (alias runtest)
  (action
   (diff string.wax string.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target string.wat.gen)
  (deps ../wax/string.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/string.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff string.wat string.wat.gen))))

(subdir wat-idempotent
 (rule
  (target string.wat.gen)
  (deps ../wasm-formatted/string.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/string.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/string.wat.gen string.wat.gen))))

(subdir wax-idempotent
 (rule
  (target string.wax.gen)
  (deps ../wax/string.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/string.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/string.wax.gen string.wax.gen))))

(subdir wax-round-trip
 (rule
  (target string.wax.gen)
  (deps ../wasm-round-trip/string.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/string.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/string.wax string.wax.gen))))

(subdir wasm-formatted
 (rule
  (target sync.wat.gen)
  (deps ../wasm-source/sync.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/sync.wat)))
 (rule
  (alias runtest)
  (action
   (diff sync.wat sync.wat.gen))))

(subdir wax
 (rule
  (target sync.wax.gen)
  (deps ../wasm-source/sync.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/sync.wat)))
 (rule
  (alias runtest)
  (action
   (diff sync.wax sync.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target sync.wat.gen)
  (deps ../wax/sync.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/sync.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff sync.wat sync.wat.gen))))

(subdir wat-idempotent
 (rule
  (target sync.wat.gen)
  (deps ../wasm-formatted/sync.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/sync.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/sync.wat.gen sync.wat.gen))))

(subdir wax-idempotent
 (rule
  (target sync.wax.gen)
  (deps ../wax/sync.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/sync.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/sync.wax.gen sync.wax.gen))))

(subdir wax-round-trip
 (rule
  (target sync.wax.gen)
  (deps ../wasm-round-trip/sync.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/sync.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/sync.wax sync.wax.gen))))

(subdir wasm-formatted
 (rule
  (target sys.wat.gen)
  (deps ../wasm-source/sys.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/sys.wat)))
 (rule
  (alias runtest)
  (action
   (diff sys.wat sys.wat.gen))))

(subdir wax
 (rule
  (target sys.wax.gen)
  (deps ../wasm-source/sys.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/sys.wat)))
 (rule
  (alias runtest)
  (action
   (diff sys.wax sys.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target sys.wat.gen)
  (deps ../wax/sys.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/sys.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff sys.wat sys.wat.gen))))

(subdir wat-idempotent
 (rule
  (target sys.wat.gen)
  (deps ../wasm-formatted/sys.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/sys.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/sys.wat.gen sys.wat.gen))))

(subdir wax-idempotent
 (rule
  (target sys.wax.gen)
  (deps ../wax/sys.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/sys.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/sys.wax.gen sys.wax.gen))))

(subdir wax-round-trip
 (rule
  (target sys.wax.gen)
  (deps ../wasm-round-trip/sys.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/sys.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/sys.wax sys.wax.gen))))

(subdir wasm-formatted
 (rule
  (target toplevel.wat.gen)
  (deps ../wasm-source/toplevel.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/toplevel.wat)))
 (rule
  (alias runtest)
  (action
   (diff toplevel.wat toplevel.wat.gen))))

(subdir wax
 (rule
  (target toplevel.wax.gen)
  (deps ../wasm-source/toplevel.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/toplevel.wat)))
 (rule
  (alias runtest)
  (action
   (diff toplevel.wax toplevel.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target toplevel.wat.gen)
  (deps ../wax/toplevel.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/toplevel.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff toplevel.wat toplevel.wat.gen))))

(subdir wat-idempotent
 (rule
  (target toplevel.wat.gen)
  (deps ../wasm-formatted/toplevel.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/toplevel.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/toplevel.wat.gen toplevel.wat.gen))))

(subdir wax-idempotent
 (rule
  (target toplevel.wax.gen)
  (deps ../wax/toplevel.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/toplevel.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/toplevel.wax.gen toplevel.wax.gen))))

(subdir wax-round-trip
 (rule
  (target toplevel.wax.gen)
  (deps ../wasm-round-trip/toplevel.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/toplevel.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/toplevel.wax toplevel.wax.gen))))

(subdir wasm-formatted
 (rule
  (target unix.wat.gen)
  (deps ../wasm-source/unix.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/unix.wat)))
 (rule
  (alias runtest)
  (action
   (diff unix.wat unix.wat.gen))))

(subdir wax
 (rule
  (target unix.wax.gen)
  (deps ../wasm-source/unix.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/unix.wat)))
 (rule
  (alias runtest)
  (action
   (diff unix.wax unix.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target unix.wat.gen)
  (deps ../wax/unix.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/unix.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff unix.wat unix.wat.gen))))

(subdir wat-idempotent
 (rule
  (target unix.wat.gen)
  (deps ../wasm-formatted/unix.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/unix.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/unix.wat.gen unix.wat.gen))))

(subdir wax-idempotent
 (rule
  (target unix.wax.gen)
  (deps ../wax/unix.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/unix.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/unix.wax.gen unix.wax.gen))))

(subdir wax-round-trip
 (rule
  (target unix.wax.gen)
  (deps ../wasm-round-trip/unix.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/unix.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/unix.wax unix.wax.gen))))

(subdir wasm-formatted
 (rule
  (target weak.wat.gen)
  (deps ../wasm-source/weak.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/weak.wat)))
 (rule
  (alias runtest)
  (action
   (diff weak.wat weak.wat.gen))))

(subdir wax
 (rule
  (target weak.wax.gen)
  (deps ../wasm-source/weak.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/weak.wat)))
 (rule
  (alias runtest)
  (action
   (diff weak.wax weak.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target weak.wat.gen)
  (deps ../wax/weak.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/weak.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff weak.wat weak.wat.gen))))

(subdir wat-idempotent
 (rule
  (target weak.wat.gen)
  (deps ../wasm-formatted/weak.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/weak.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/weak.wat.gen weak.wat.gen))))

(subdir wax-idempotent
 (rule
  (target weak.wax.gen)
  (deps ../wax/weak.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/weak.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/weak.wax.gen weak.wax.gen))))

(subdir wax-round-trip
 (rule
  (target weak.wax.gen)
  (deps ../wasm-round-trip/weak.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/weak.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/weak.wax weak.wax.gen))))

(subdir wasm-formatted
 (rule
  (target zstd.wat.gen)
  (deps ../wasm-source/zstd.wat)
  (action
   (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-source/zstd.wat)))
 (rule
  (alias runtest)
  (action
   (diff zstd.wat zstd.wat.gen))))

(subdir wax
 (rule
  (target zstd.wax.gen)
  (deps ../wasm-source/zstd.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-source/zstd.wat)))
 (rule
  (alias runtest)
  (action
   (diff zstd.wax zstd.wax.gen))))

(subdir wasm-round-trip
 (rule
  (target zstd.wat.gen)
  (deps ../wax/zstd.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wat -o %{target} ../wax/zstd.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff zstd.wat zstd.wat.gen))))

(subdir wat-idempotent
 (rule
  (target zstd.wat.gen)
  (deps ../wasm-formatted/zstd.wat.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wat -o %{target} ../wasm-formatted/zstd.wat.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wasm-formatted/zstd.wat.gen zstd.wat.gen))))

(subdir wax-idempotent
 (rule
  (target zstd.wax.gen)
  (deps ../wax/zstd.wax.gen)
 (action
  (run wax --validate -W unused-local=hidden --input-format wax --format wax -o %{target} ../wax/zstd.wax.gen)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/zstd.wax.gen zstd.wax.gen))))

(subdir wax-round-trip
 (rule
  (target zstd.wax.gen)
  (deps ../wasm-round-trip/zstd.wat)
 (action
  (run wax --validate -W unused-local=hidden --input-format wat --format wax -o %{target} ../wasm-round-trip/zstd.wat)))
 (rule
  (alias runtest)
  (action
   (diff ../wax/zstd.wax zstd.wax.gen))))

