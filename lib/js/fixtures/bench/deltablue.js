// DeltaBlue: the incremental dataflow constraint solver of Freeman-Benson,
// Maloney and Borning ("An Incremental Constraint Solver", CACM 1990), the
// classic object-oriented benchmark. Written for Wiffer (ROADMAP Phase 9J)
// from the paper's algorithm, in the shape of the well-known Smalltalk and
// JavaScript versions: a chain test (a long chain of equality constraints
// re-planned and executed) and a projection test (scale constraints
// edited from both ends). Both tests check their results.
//
// Prints "bench deltablue <ms> ms <result>" when console exists (/bin/js);
// the completion value is the result (host tests).

function dbInherits(child, parent) {
  function T() {}
  T.prototype = parent.prototype;
  child.prototype = new T();
  child.prototype.constructor = child;
  child.superConstructor = parent;
}

function dbFail(what) { throw new Error("deltablue: " + what); }

// An ordered collection with the operations the solver needs.
function OrderedCollection() { this.elms = []; }
OrderedCollection.prototype.add = function (elm) { this.elms.push(elm); };
OrderedCollection.prototype.at = function (index) { return this.elms[index]; };
OrderedCollection.prototype.size = function () { return this.elms.length; };
OrderedCollection.prototype.removeFirst = function () { return this.elms.shift(); };
OrderedCollection.prototype.remove = function (elm) {
  var index = 0, skipped = 0;
  for (var i = 0; i < this.elms.length; i++) {
    var value = this.elms[i];
    if (value != elm) { this.elms[index] = value; index++; } else { skipped++; }
  }
  for (var j = 0; j < skipped; j++) this.elms.pop();
};

// Strengths: lower values are stronger.
function Strength(strengthValue, name) {
  this.strengthValue = strengthValue;
  this.name = name;
}
Strength.stronger = function (s1, s2) { return s1.strengthValue < s2.strengthValue; };
Strength.weaker = function (s1, s2) { return s1.strengthValue > s2.strengthValue; };
Strength.weakestOf = function (s1, s2) { return Strength.weaker(s1, s2) ? s1 : s2; };
Strength.prototype.nextWeaker = function () {
  switch (this.strengthValue) {
    case 0: return Strength.STRONG_PREFERRED;
    case 1: return Strength.PREFERRED;
    case 2: return Strength.STRONG_DEFAULT;
    case 3: return Strength.NORMAL;
    case 4: return Strength.WEAK_DEFAULT;
    default: return Strength.WEAKEST;
  }
};
Strength.REQUIRED = new Strength(0, "required");
Strength.STRONG_PREFERRED = new Strength(1, "strongPreferred");
Strength.PREFERRED = new Strength(2, "preferred");
Strength.STRONG_DEFAULT = new Strength(3, "strongDefault");
Strength.NORMAL = new Strength(4, "normal");
Strength.WEAK_DEFAULT = new Strength(5, "weakDefault");
Strength.WEAKEST = new Strength(6, "weakest");

var planner = null;

// Constraint: the abstract superclass.
function Constraint(strength) { this.strength = strength; }
Constraint.prototype.addConstraint = function () {
  this.addToGraph();
  planner.incrementalAdd(this);
};
// Satisfies this constraint if possible and returns the constraint it
// overrode, if any.
Constraint.prototype.satisfy = function (mark) {
  this.chooseMethod(mark);
  if (!this.isSatisfied()) {
    if (this.strength == Strength.REQUIRED) dbFail("could not satisfy a required constraint");
    return null;
  }
  this.markInputs(mark);
  var out = this.output();
  var overridden = out.determinedBy;
  if (overridden != null) overridden.markUnsatisfied();
  out.determinedBy = this;
  if (!planner.addPropagate(this, mark)) dbFail("cycle encountered");
  out.mark = mark;
  return overridden;
};
Constraint.prototype.destroyConstraint = function () {
  if (this.isSatisfied()) planner.incrementalRemove(this);
  else this.removeFromGraph();
};
Constraint.prototype.isInput = function () { return false; };

// UnaryConstraint: one output variable.
function UnaryConstraint(v, strength) {
  UnaryConstraint.superConstructor.call(this, strength);
  this.myOutput = v;
  this.satisfied = false;
  this.addConstraint();
}
dbInherits(UnaryConstraint, Constraint);
UnaryConstraint.prototype.addToGraph = function () {
  this.myOutput.addConstraint(this);
  this.satisfied = false;
};
UnaryConstraint.prototype.chooseMethod = function (mark) {
  this.satisfied = this.myOutput.mark != mark && Strength.stronger(this.strength, this.myOutput.walkStrength);
};
UnaryConstraint.prototype.isSatisfied = function () { return this.satisfied; };
UnaryConstraint.prototype.markInputs = function (mark) {};
UnaryConstraint.prototype.output = function () { return this.myOutput; };
UnaryConstraint.prototype.recalculate = function () {
  this.myOutput.walkStrength = this.strength;
  this.myOutput.stay = !this.isInput();
  if (this.myOutput.stay) this.execute();
};
UnaryConstraint.prototype.markUnsatisfied = function () { this.satisfied = false; };
UnaryConstraint.prototype.inputsKnown = function () { return true; };
UnaryConstraint.prototype.removeFromGraph = function () {
  if (this.myOutput != null) this.myOutput.removeConstraint(this);
  this.satisfied = false;
};

// StayConstraint: the variable keeps its value.
function StayConstraint(v, str) { StayConstraint.superConstructor.call(this, v, str); }
dbInherits(StayConstraint, UnaryConstraint);
StayConstraint.prototype.execute = function () {};

// EditConstraint: the variable is being changed from outside.
function EditConstraint(v, str) { EditConstraint.superConstructor.call(this, v, str); }
dbInherits(EditConstraint, UnaryConstraint);
EditConstraint.prototype.isInput = function () { return true; };
EditConstraint.prototype.execute = function () {};

var DIRECTION_NONE = 0, DIRECTION_FORWARD = 1, DIRECTION_BACKWARD = -1;

// BinaryConstraint: two variables, either may be the output.
function BinaryConstraint(var1, var2, strength) {
  BinaryConstraint.superConstructor.call(this, strength);
  this.v1 = var1;
  this.v2 = var2;
  this.direction = DIRECTION_NONE;
  this.addConstraint();
}
dbInherits(BinaryConstraint, Constraint);
BinaryConstraint.prototype.chooseMethod = function (mark) {
  if (this.v1.mark == mark) {
    this.direction = this.v2.mark != mark && Strength.stronger(this.strength, this.v2.walkStrength)
      ? DIRECTION_FORWARD : DIRECTION_NONE;
  } else if (this.v2.mark == mark) {
    this.direction = this.v1.mark != mark && Strength.stronger(this.strength, this.v1.walkStrength)
      ? DIRECTION_BACKWARD : DIRECTION_NONE;
  } else if (Strength.weaker(this.v1.walkStrength, this.v2.walkStrength)) {
    this.direction = Strength.stronger(this.strength, this.v1.walkStrength) ? DIRECTION_BACKWARD : DIRECTION_NONE;
  } else {
    this.direction = Strength.stronger(this.strength, this.v2.walkStrength) ? DIRECTION_FORWARD : DIRECTION_BACKWARD;
  }
};
BinaryConstraint.prototype.addToGraph = function () {
  this.v1.addConstraint(this);
  this.v2.addConstraint(this);
  this.direction = DIRECTION_NONE;
};
BinaryConstraint.prototype.isSatisfied = function () { return this.direction != DIRECTION_NONE; };
BinaryConstraint.prototype.markInputs = function (mark) { this.input().mark = mark; };
BinaryConstraint.prototype.input = function () { return this.direction == DIRECTION_FORWARD ? this.v1 : this.v2; };
BinaryConstraint.prototype.output = function () { return this.direction == DIRECTION_FORWARD ? this.v2 : this.v1; };
BinaryConstraint.prototype.recalculate = function () {
  var ihn = this.input(), out = this.output();
  out.walkStrength = Strength.weakestOf(this.strength, ihn.walkStrength);
  out.stay = ihn.stay;
  if (out.stay) this.execute();
};
BinaryConstraint.prototype.markUnsatisfied = function () { this.direction = DIRECTION_NONE; };
BinaryConstraint.prototype.inputsKnown = function (mark) {
  var i = this.input();
  return i.mark == mark || i.stay || i.determinedBy == null;
};
BinaryConstraint.prototype.removeFromGraph = function () {
  if (this.v1 != null) this.v1.removeConstraint(this);
  if (this.v2 != null) this.v2.removeConstraint(this);
  this.direction = DIRECTION_NONE;
};

// ScaleConstraint: v2 = v1 * scale + offset, in either direction.
function ScaleConstraint(src, scale, offset, dest, strength) {
  this.direction = DIRECTION_NONE;
  this.scale = scale;
  this.offset = offset;
  ScaleConstraint.superConstructor.call(this, src, dest, strength);
}
dbInherits(ScaleConstraint, BinaryConstraint);
ScaleConstraint.prototype.addToGraph = function () {
  BinaryConstraint.prototype.addToGraph.call(this);
  this.scale.addConstraint(this);
  this.offset.addConstraint(this);
};
ScaleConstraint.prototype.removeFromGraph = function () {
  BinaryConstraint.prototype.removeFromGraph.call(this);
  if (this.scale != null) this.scale.removeConstraint(this);
  if (this.offset != null) this.offset.removeConstraint(this);
};
ScaleConstraint.prototype.markInputs = function (mark) {
  BinaryConstraint.prototype.markInputs.call(this, mark);
  this.scale.mark = this.offset.mark = mark;
};
ScaleConstraint.prototype.execute = function () {
  if (this.direction == DIRECTION_FORWARD) this.v2.value = this.v1.value * this.scale.value + this.offset.value;
  else this.v1.value = (this.v2.value - this.offset.value) / this.scale.value;
};
ScaleConstraint.prototype.recalculate = function () {
  var ihn = this.input(), out = this.output();
  out.walkStrength = Strength.weakestOf(this.strength, ihn.walkStrength);
  out.stay = ihn.stay && this.scale.stay && this.offset.stay;
  if (out.stay) this.execute();
};

// EqualityConstraint: v1 == v2.
function EqualityConstraint(var1, var2, strength) {
  EqualityConstraint.superConstructor.call(this, var1, var2, strength);
}
dbInherits(EqualityConstraint, BinaryConstraint);
EqualityConstraint.prototype.execute = function () { this.output().value = this.input().value; };

// Variable: a value and the constraints on it.
function Variable(name, initialValue) {
  this.value = initialValue || 0;
  this.constraints = new OrderedCollection();
  this.determinedBy = null;
  this.mark = 0;
  this.walkStrength = Strength.WEAKEST;
  this.stay = true;
  this.name = name;
}
Variable.prototype.addConstraint = function (c) { this.constraints.add(c); };
Variable.prototype.removeConstraint = function (c) {
  this.constraints.remove(c);
  if (this.determinedBy == c) this.determinedBy = null;
};

// Planner: incremental addition and removal, and plan extraction.
function Planner() { this.currentMark = 0; }
Planner.prototype.incrementalAdd = function (c) {
  var mark = this.newMark();
  var overridden = c.satisfy(mark);
  while (overridden != null) overridden = overridden.satisfy(mark);
};
Planner.prototype.incrementalRemove = function (c) {
  var out = c.output();
  c.markUnsatisfied();
  c.removeFromGraph();
  var unsatisfied = this.removePropagateFrom(out);
  var strength = Strength.REQUIRED;
  do {
    for (var i = 0; i < unsatisfied.size(); i++) {
      var u = unsatisfied.at(i);
      if (u.strength == strength) this.incrementalAdd(u);
    }
    strength = strength.nextWeaker();
  } while (strength != Strength.WEAKEST);
};
Planner.prototype.newMark = function () { return ++this.currentMark; };
Planner.prototype.makePlan = function (sources) {
  var mark = this.newMark();
  var plan = new Plan();
  var todo = sources;
  while (todo.size() > 0) {
    var c = todo.removeFirst();
    if (c.output().mark != mark && c.inputsKnown(mark)) {
      plan.addConstraint(c);
      c.output().mark = mark;
      this.addConstraintsConsumingTo(c.output(), todo);
    }
  }
  return plan;
};
Planner.prototype.extractPlanFromConstraints = function (constraints) {
  var sources = new OrderedCollection();
  for (var i = 0; i < constraints.size(); i++) {
    var c = constraints.at(i);
    if (c.isInput() && c.isSatisfied()) sources.add(c);
  }
  return this.makePlan(sources);
};
Planner.prototype.addPropagate = function (c, mark) {
  var todo = new OrderedCollection();
  todo.add(c);
  while (todo.size() > 0) {
    var d = todo.removeFirst();
    if (d.output().mark == mark) {
      this.incrementalRemove(c);
      return false;
    }
    d.recalculate();
    this.addConstraintsConsumingTo(d.output(), todo);
  }
  return true;
};
Planner.prototype.removePropagateFrom = function (out) {
  out.determinedBy = null;
  out.walkStrength = Strength.WEAKEST;
  out.stay = true;
  var unsatisfied = new OrderedCollection();
  var todo = new OrderedCollection();
  todo.add(out);
  while (todo.size() > 0) {
    var v = todo.removeFirst();
    for (var i = 0; i < v.constraints.size(); i++) {
      var c = v.constraints.at(i);
      if (!c.isSatisfied()) unsatisfied.add(c);
    }
    var determining = v.determinedBy;
    for (var j = 0; j < v.constraints.size(); j++) {
      var next = v.constraints.at(j);
      if (next != determining && next.isSatisfied()) {
        next.recalculate();
        todo.add(next.output());
      }
    }
  }
  return unsatisfied;
};
Planner.prototype.addConstraintsConsumingTo = function (v, coll) {
  var determining = v.determinedBy;
  var cc = v.constraints;
  for (var i = 0; i < cc.size(); i++) {
    var c = cc.at(i);
    if (c != determining && c.isSatisfied()) coll.add(c);
  }
};

// Plan: an ordered list of constraints to execute.
function Plan() { this.v = new OrderedCollection(); }
Plan.prototype.addConstraint = function (c) { this.v.add(c); };
Plan.prototype.size = function () { return this.v.size(); };
Plan.prototype.constraintAt = function (index) { return this.v.at(index); };
Plan.prototype.execute = function () {
  for (var i = 0; i < this.size(); i++) this.constraintAt(i).execute();
};

function chainTest(n) {
  planner = new Planner();
  var prev = null, first = null, last = null;
  for (var i = 0; i <= n; i++) {
    var v = new Variable("v" + i);
    if (prev != null) new EqualityConstraint(prev, v, Strength.REQUIRED);
    if (i == 0) first = v;
    if (i == n) last = v;
    prev = v;
  }
  new StayConstraint(last, Strength.STRONG_DEFAULT);
  var edit = new EditConstraint(first, Strength.PREFERRED);
  var edits = new OrderedCollection();
  edits.add(edit);
  var plan = planner.extractPlanFromConstraints(edits);
  for (var k = 0; k < 100; k++) {
    first.value = k;
    plan.execute();
    if (last.value != k) dbFail("chain test: " + last.value + " != " + k);
  }
  return last.value;
}

function change(v, newValue) {
  var edit = new EditConstraint(v, Strength.PREFERRED);
  var edits = new OrderedCollection();
  edits.add(edit);
  var plan = planner.extractPlanFromConstraints(edits);
  for (var i = 0; i < 10; i++) {
    v.value = newValue;
    plan.execute();
  }
  edit.destroyConstraint();
}

function projectionTest(n) {
  planner = new Planner();
  var scale = new Variable("scale", 10);
  var offset = new Variable("offset", 1000);
  var src = null, dst = null;
  var dests = new OrderedCollection();
  for (var i = 0; i < n; i++) {
    src = new Variable("src" + i, i);
    dst = new Variable("dst" + i, i);
    dests.add(dst);
    new StayConstraint(src, Strength.NORMAL);
    new ScaleConstraint(src, scale, offset, dst, Strength.REQUIRED);
  }
  change(src, 17);
  if (dst.value != 1170) dbFail("projection 1: " + dst.value);
  change(dst, 1050);
  if (src.value != 5) dbFail("projection 2: " + src.value);
  change(scale, 5);
  for (var j = 0; j < n - 1; j++) {
    if (dests.at(j).value != j * 5 + 1000) dbFail("projection 3");
  }
  change(offset, 2000);
  for (var k = 0; k < n - 1; k++) {
    if (dests.at(k).value != k * 5 + 2000) dbFail("projection 4");
  }
  return dests.at(n - 2).value;
}

function deltaBlue() { return chainTest(100) + "/" + projectionTest(100); }

var benchRuns = typeof benchScale === "number" ? benchScale : 20;
var benchT0 = Date.now();
var benchResult;
for (var benchI = 0; benchI < benchRuns; benchI++) benchResult = deltaBlue();
if (typeof console !== "undefined") console.log("bench deltablue " + (Date.now() - benchT0) + " ms x" + benchRuns + " " + benchResult);
benchResult;
