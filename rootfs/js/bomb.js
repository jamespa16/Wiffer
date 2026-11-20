// Never stops allocating: the heap cap terminates it.
console.log("allocating");
var keep = [];
while (true) { keep.push("x".repeat(1000000) + keep.length); }
