// The user-agent stylesheet: the HTML Standard's "Rendering" section
// (https://html.spec.whatwg.org/#rendering) in the parts a static page needs,
// with the browser's form control defaults kept simple.

let cssUserAgentStyleSheetSource = #"""
html, body { display: block }
html { color: black; background-color: transparent }
body { margin: 8px }

[hidden], area, base, basefont, datalist, head, link, meta, noembed, noframes, param, rp,
script, style, template, title { display: none }
dialog:not([open]) { display: none }
audio:not([controls]) { display: none }
slot { display: contents }

address, blockquote, center, dialog, div, figure, figcaption, footer, form, header, hr,
legend, listing, main, p, plaintext, pre, search, xmp, article, aside, h1, h2, h3, h4, h5, h6,
hgroup, nav, section, dir, dd, dl, dt, menu, ol, ul, details, summary, fieldset, optgroup, option { display: block }
li { display: list-item }

table { display: table }
caption { display: table-caption }
colgroup, colgroup[hidden] { display: table-column-group }
col, col[hidden] { display: table-column }
thead { display: table-header-group }
tbody { display: table-row-group }
tfoot { display: table-footer-group }
tr { display: table-row }
td, th { display: table-cell }
input, select, button, textarea, meter, progress { display: inline-block }

address, cite, dfn, em, i, var { font-style: italic }
b, strong { font-weight: bolder }
h1, h2, h3, h4, h5, h6, th, optgroup { font-weight: bold }
u, ins { text-decoration: underline }
s, strike, del { text-decoration: line-through }
big { font-size: larger }
small { font-size: smaller }
sub { vertical-align: sub; font-size: smaller }
sup { vertical-align: super; font-size: smaller }
code, kbd, samp, tt, pre, listing, xmp, plaintext, textarea { font-family: monospace }
pre, listing, xmp, plaintext { white-space: pre }
nobr { white-space: nowrap }
mark { background-color: yellow; color: black }
q::before { content: open-quote }
q::after { content: close-quote }

h1 { margin-top: 0.67em; margin-bottom: 0.67em; font-size: 2em }
h2 { margin-top: 0.83em; margin-bottom: 0.83em; font-size: 1.5em }
h3 { margin-top: 1em; margin-bottom: 1em; font-size: 1.17em }
h4 { margin-top: 1.33em; margin-bottom: 1.33em; font-size: 1em }
h5 { margin-top: 1.67em; margin-bottom: 1.67em; font-size: 0.83em }
h6 { margin-top: 2.33em; margin-bottom: 2.33em; font-size: 0.67em }
p, dl, pre, listing, xmp, plaintext, fieldset, ul, ol, menu, dir { margin-top: 1em; margin-bottom: 1em }
blockquote, figure { margin: 1em 40px }
dd { margin-left: 40px }
ul, ol, menu, dir { padding-left: 40px }
:is(dir, dl, menu, ol, ul) :is(dir, dl, menu, ol, ul) { margin-top: 0; margin-bottom: 0 }
ul, menu, dir { list-style-type: disc }
ol { list-style-type: decimal }
ul ul, ol ul, menu ul, dir ul { list-style-type: circle }
ul ul ul, ol ul ul, ul ol ul, ol ol ul, menu ul ul, dir ul ul { list-style-type: square }
ol[type="1"] { list-style-type: decimal }
ol[type="a"] { list-style-type: lower-alpha }
ol[type="A"] { list-style-type: upper-alpha }
ol[type="i"] { list-style-type: lower-roman }
ol[type="I"] { list-style-type: upper-roman }
ul[type="disc" i] { list-style-type: disc }
ul[type="circle" i] { list-style-type: circle }
ul[type="square" i] { list-style-type: square }

center { text-align: center }
hr { color: gray; border-style: inset; border-width: 1px; margin-top: 0.5em; margin-bottom: 0.5em;
     margin-left: auto; margin-right: auto; overflow: hidden }

table { box-sizing: border-box; border-spacing: 2px; border-collapse: separate; text-indent: 0; border-color: gray }
td, th { padding: 1px }
th { text-align: center }
caption { text-align: center }
thead, tbody, tfoot { vertical-align: middle }
tr, td, th { vertical-align: inherit }

a:link, a:visited, area:link { text-decoration: underline; cursor: pointer }
a:link, area:link { color: #0000ee }
a:visited { color: #551a8b }

input, select, textarea, button { margin: 0; font-family: sans-serif; font-size: 13.3333px; text-indent: 0; line-height: normal }
input, textarea, select { background-color: white; color: black; border: 2px inset gray; padding: 1px 2px }
button, input[type="submit" i], input[type="reset" i], input[type="button" i] {
    background-color: #efefef; color: black; border: 2px outset gray; padding: 1px 6px; text-align: center }
input[type="checkbox" i], input[type="radio" i] { padding: 0; border-width: 0; background-color: transparent }
input[type="hidden" i] { display: none }
textarea { white-space: pre-wrap }
fieldset { margin-left: 2px; margin-right: 2px; padding: 0.35em 0.75em 0.625em; border: 2px groove gray }
legend { padding-left: 2px; padding-right: 2px }
img { border-width: 0 }
iframe { border: 2px inset gray }
"""#

/// The built-in user agent sheet, parsed.
func cssUserAgentStyleSheet() -> CSSStylesheet {
    cssParseStylesheet(cssUserAgentStyleSheetSource)
}
