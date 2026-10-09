// This file intentionally panics

// panic "test";

// (fn () -> Nil {
//     panic "test";
// })();

// fn one() -> Nil {
//     fn two() -> Nil {
//         fn three() -> Nil {
//             fn four() -> Nil {
//                 fn five() -> Nil {
//                     var test = fn () -> Nil {
//                         panic "in anonymous";
//                     }();
//                 }
//                 five();
//             }
//             four();
//         }
//         three();
//     }
//     two();
// }
// one();
