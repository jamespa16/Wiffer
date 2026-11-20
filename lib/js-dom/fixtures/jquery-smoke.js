// jQuery 3.7.1 smoke test (lib/js-dom host tests): selectors, traversal,
// manipulation, attributes, CSS, events, data, deferreds and utilities.
// Each check logs "ok <name>" or "FAIL <name>: <detail>"; the host test
// expects every line to be ok and the final "done" line.
(function () {
  var log = function (s) { console.log(s); };
  function check(name, got, want) {
    if (got === want) log("ok " + name);
    else log("FAIL " + name + ": got " + JSON.stringify(got) + ", want " + JSON.stringify(want));
  }

  // Selectors.
  check("version", typeof jQuery.fn.jquery, "string");
  check("$ by id", $("#list").length, 1);
  check("$ by tag", $("li").length, 4);
  check("$ by class", $(".item").length, 3);
  check("$ descendant", $("#list li.item").length, 3);
  check("$ attribute", $("a[href^='http']").length, 1);
  check("$ :first", $("li:first").text(), "one");
  check("$ :last", $("li:last").text(), "four");
  check("$ :eq", $("li:eq(1)").text(), "two");
  check("$ :even", $("li:even").length, 2);
  check("$ :not", $("li:not(.item)").length, 1);
  check("$ :contains", $("li:contains('thr')").text(), "three");
  check("$ :has", $("div:has(span)").attr("id"), "box");
  check("$ :checked", $("input:checked").length, 1);
  check("$ comma", $("#box, #list").length, 2);
  check("$ context", $("span", "#box").length, 2);

  // Traversal.
  check("find", $("#box").find("span").length, 2);
  check("children", $("#list").children().length, 4);
  check("parent", $("li:first").parent().attr("id"), "list");
  check("closest", $("span.inner").closest("div").attr("id"), "box");
  check("parents", $("span.inner").parents().length >= 3, true);
  check("siblings", $("li:first").siblings().length, 3);
  check("next", $("li:first").next().text(), "two");
  check("prev", $("li:last").prev().text(), "three");
  check("filter", $("li").filter(".item").length, 3);
  check("not", $("li").not(".item").length, 1);
  check("is", $("li:first").is(".item"), true);
  check("eq", $("li").eq(2).text(), "three");
  check("first/last", $("li").first().text() + $("li").last().text(), "onefour");
  check("index", $("li.special").index(), 3);
  check("add", $("#box").add("#list").length, 2);
  check("end", $("#box").find("span").end().attr("id"), "box");

  // Manipulation.
  $("#list").append("<li class='item new'>five</li>");
  check("append", $("#list li").length, 5);
  $("#list").prepend($("<li>zero</li>"));
  check("prepend", $("#list li:first").text(), "zero");
  $("li.new").after("<li>six</li>").before("<li>4.5</li>");
  check("after/before", $("#list li").map(function () { return $(this).text(); }).get().join(","),
        "zero,one,two,three,four,4.5,five,six");
  $("#list li:contains('4.5')").remove();
  check("remove", $("#list li").length, 7);
  check("html get", $("#box").html().indexOf("<span") >= 0, true);
  $("#target").html("<b>bold</b> text");
  check("html set", $("#target b").text(), "bold");
  check("text get", $("#target").text(), "bold text");
  $("#target").text("<plain>");
  check("text set escapes", $("#target").html(), "&lt;plain&gt;");
  $("#target").empty();
  check("empty", $("#target").contents().length, 0);
  var clone = $("#box").clone().attr("id", "box2").appendTo("body");
  check("clone", $("#box2 span").length, 2);
  clone.remove();
  check("clone removed", $("#box2").length, 0);
  $("span.inner").wrap("<em class='wrapper'></em>");
  check("wrap", $("em.wrapper > span.inner").length, 1);
  $("span.inner").unwrap();
  check("unwrap", $("em.wrapper").length, 0);
  $("#list li:first").replaceWith("<li>ZERO</li>");
  check("replaceWith", $("#list li:first").text(), "ZERO");
  var parsed = $.parseHTML("<p>a</p><p>b</p>");
  check("parseHTML", parsed.length, 2);
  check("$(html)", $("<div><p>x</p><p>y</p></div>").find("p").length, 2);

  // Attributes and properties.
  check("attr get", $("a").attr("href"), "http://example.test/");
  $("a").attr("title", "hello");
  check("attr set", $("a")[0].getAttribute("title"), "hello");
  $("a").removeAttr("title");
  check("removeAttr", $("a").attr("title"), undefined);
  check("prop", $("#c1").prop("checked"), true);
  $("#c1").prop("checked", false);
  check("prop set", $("#c1")[0].checked, false);
  check("val get", $("#name").val(), "Ada");
  $("#name").val("Grace");
  check("val set", $("#name")[0].value, "Grace");
  check("val select", $("#sel").val(), "b");
  $("#sel").val("c");
  check("val select set", $("#sel")[0].selectedIndex, 2);
  $("#box").addClass("a b");
  check("addClass", $("#box")[0].className, "box a b");
  $("#box").removeClass("a");
  check("removeClass", $("#box").hasClass("a") + "," + $("#box").hasClass("b"), "false,true");
  $("#box").toggleClass("b");
  check("toggleClass", $("#box").hasClass("b"), false);
  check("data attr", $("#box").data("role"), "panel");
  $("#box").data("count", 3);
  check("data set", $("#box").data("count"), 3);
  check("data camel", $("#box").data("longName"), "x");

  // CSS.
  $("#box").css("color", "red");
  check("css set", $("#box")[0].style.color, "red");
  $("#box").css({ backgroundColor: "blue", width: 100 });
  check("css map", $("#box")[0].style.backgroundColor + " " + $("#box")[0].style.width, "blue 100px");
  check("css get inline", $("#box").css("width"), "100px");
  $("#hidden").show();
  check("show", $("#hidden")[0].style.display, "");
  $("#box").hide();
  check("hide", $("#box")[0].style.display, "none");
  $("#box").show();
  check("show again", $("#box")[0].style.display, "");

  // Events.
  var clicks = [];
  $("#list").on("click", "li", function (e) { clicks.push($(this).text()); });
  $("#list li:eq(2)").trigger("click");
  check("delegated on/trigger", clicks.join(","), "two");
  $("#list li:eq(2)")[0].click();
  check("native click delegated", clicks.join(","), "two,two");
  var custom = null;
  $("#box").on("custom.ns", function (e, a, b) { custom = e.type + ":" + a + b; });
  $("#box").trigger("custom", ["x", "y"]);
  check("custom event with args", custom, "custom:xy");
  $("#box").off(".ns");
  custom = null;
  $("#box").trigger("custom");
  check("off namespace", custom, null);
  var once = 0;
  $("#box").one("ping", function () { once++; });
  $("#box").trigger("ping").trigger("ping");
  check("one", once, 1);
  var prevented = null;
  $("a").on("click", function (e) { e.preventDefault(); prevented = e.isDefaultPrevented(); });
  $("a")[0].click();
  check("preventDefault via jQuery", prevented, true);
  var bubbled = false;
  $(document).on("bubble-test", function () { bubbled = true; });
  $("span.inner").trigger("bubble-test");
  check("trigger bubbles to document", bubbled, true);
  var stopped = true;
  $(document).on("stop-test", function () { stopped = false; });
  $("span.inner").on("stop-test", function (e) { e.stopPropagation(); });
  $("span.inner").trigger("stop-test");
  check("stopPropagation", stopped, true);
  var focusCount = 0;
  $("#name").on("focus", function () { focusCount++; });
  $("#name").trigger("focus");
  check("focus trigger", focusCount >= 1 && document.activeElement === $("#name")[0], true);

  // each / map / utilities.
  var texts = [];
  $("#list li").each(function (i, el) { texts.push(i + el.textContent); });
  check("each", texts[1], "1one");
  check("$.each", (function () { var s = 0; $.each([1, 2, 3], function (i, v) { s += v; }); return s; })(), 6);
  check("$.map", $.map([1, 2, 3], function (v) { return v * 2; }).join(","), "2,4,6");
  check("$.extend", $.extend({ a: 1 }, { b: 2 }, { a: 3 }).a, 3);
  check("$.extend deep", $.extend(true, { a: { x: 1 } }, { a: { y: 2 } }).a.x, 1);
  check("$.grep", $.grep([1, 2, 3, 4], function (v) { return v % 2; }).length, 2);
  check("$.inArray", $.inArray(3, [1, 2, 3]), 2);
  check("$.isPlainObject", $.isPlainObject({}) && !$.isPlainObject(document), true);
  check("$.trim", jQuery.trim ? jQuery.trim("  x ") : "x", "x");
  check("$.param", $.param({ a: 1, b: [2, 3] }), "a=1&b%5B%5D=2&b%5B%5D=3");
  check("serialize", $("#form").serialize(), "name=Grace&c1=on&sel=c".replace("&c1=on", ""));
  check("serializeArray", $("#form").serializeArray().length, 2);
  check("$.contains", $.contains(document.documentElement, $("#box")[0]), true);
  check("$.escapeSelector", $.escapeSelector("a.b"), "a\\.b");

  // Deferreds.
  var order = [];
  var d = $.Deferred();
  d.done(function (v) { order.push("done" + v); }).always(function () { order.push("always"); });
  d.resolve(1);
  check("deferred done", order.join(","), "done1,always");
  var d2 = $.Deferred();
  d2.fail(function (e) { order.push("fail" + e); });
  d2.reject("x");
  check("deferred fail", order[order.length - 1], "failx");
  var whenResult = null;
  $.when($.Deferred().resolve(1), $.Deferred().resolve(2)).done(function (a, b) { whenResult = a + b; });
  check("$.when", whenResult, 3);
  check("deferred state", d.state() + "," + d2.state(), "resolved,rejected");
  var thenValue = null;
  $.Deferred().resolve(2).then(function (v) { return v * 10; }).then(function (v) { thenValue = v; log("ok deferred then async " + v); });
  check("deferred then is async", thenValue, null);

  // Ready.
  $(function () { log("ok ready callback"); });

  // Animation (jQuery.fx off: instant).
  jQuery.fx.off = true;
  $("#box").fadeOut();
  check("fadeOut with fx.off", $("#box")[0].style.display, "none");
  $("#box").fadeIn();
  check("fadeIn with fx.off", $("#box")[0].style.display, "");

  setTimeout(function () { log("done"); }, 0);
})();
