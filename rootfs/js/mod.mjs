// An ES module with a dependency, top-level await and a promise chain.
import { square, name } from "./dep.mjs";
console.log("module " + name + " " + square(12));
const v = await new Promise((resolve) => setTimeout(() => resolve("awaited"), 50));
console.log(v);
Promise.reject(new Error("unhandled on purpose"));
