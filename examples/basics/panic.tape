// This file intentionally panics

// panic "test";

// TODO: this crashes because the anonymous function is at the declaration position

// fn () -> Nil {
// };

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
