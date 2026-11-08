#!/usr/bin/env python3
"""Execute the shared target-selection listbox lifecycle with a DOM fixture."""

from html.parser import HTMLParser
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / "web-ui"))
import server  # noqa: E402


class InlineScripts(HTMLParser):
    def __init__(self):
        super().__init__()
        self.scripts = []
        self._inside = False
        self._parts = []

    def handle_starttag(self, tag, attrs):
        if tag == "script":
            self._inside = True
            self._parts = []

    def handle_endtag(self, tag):
        if tag == "script" and self._inside:
            self.scripts.append("".join(self._parts))
            self._inside = False

    def handle_data(self, data):
        if self._inside:
            self._parts.append(data)


parser = InlineScripts()
parser.feed(server.PAGE)
script = next(item for item in parser.scripts if "const buildNodeSelectionField" in item)
start = script.index("const selectionMenuOptions=")
end = script.index("if(!selectionMenuDocumentHandlerInstalled)", start)
listbox_source = script[start:end]

fixture = r"""
class ClassList {
  constructor(owner) { this.owner = owner; }
  _items() { return this.owner.className.split(/\s+/).filter(Boolean); }
  contains(name) { return this._items().includes(name); }
  add(...names) { const values = new Set(this._items()); names.forEach(name => values.add(name)); this.owner.className = [...values].join(' '); }
  remove(...names) { const values = new Set(this._items()); names.forEach(name => values.delete(name)); this.owner.className = [...values].join(' '); }
}

class Element {
  constructor(tag) {
    this.nodeType = 1;
    this.tagName = tag.toUpperCase();
    this.children = [];
    this.parentNode = null;
    this.attributes = new Map();
    this.dataset = {};
    this.style = {};
    this.className = '';
    this.classList = new ClassList(this);
    this.hidden = false;
    this.disabled = false;
    this.tabIndex = 0;
    this.textContent = '';
    this.onclick = null;
    this.onkeydown = null;
    this._rect = null;
  }
  appendChild(child) { child.parentNode = this; this.children.push(child); return child; }
  append(...children) { children.forEach(child => this.appendChild(child)); }
  removeChild(child) { const index = this.children.indexOf(child); if (index >= 0) { this.children.splice(index, 1); child.parentNode = null; } return child; }
  remove() { this.parentNode?.removeChild(this); }
  replaceChildren(...children) { while (this.children.length) this.removeChild(this.children[0]); this.append(...children); }
  setAttribute(name, value) { this.attributes.set(name, String(value)); if (name === 'id') this.id = String(value); }
  getAttribute(name) { return this.attributes.get(name) ?? null; }
  removeAttribute(name) { this.attributes.delete(name); if (name === 'id') this.id = ''; }
  matches(selector) {
    if (selector.startsWith('.')) return selector.slice(1).split('.').every(name => this.classList.contains(name));
    if (selector === '[role="option"]') return this.getAttribute('role') === 'option';
    return false;
  }
  closest(selector) { for (let item = this; item; item = item.parentNode) if (item.matches?.(selector)) return item; return null; }
  querySelectorAll(selector) {
    const result = [];
    const visit = node => { node.children.forEach(child => { if (child.matches(selector)) result.push(child); visit(child); }); };
    visit(this);
    return result;
  }
  querySelector(selector) { return this.querySelectorAll(selector)[0] ?? null; }
  get isConnected() { return Boolean(this.parentNode) && (this.parentNode === document.body || this.parentNode.isConnected); }
  getBoundingClientRect() { return this._rect || (this.classList.contains('target-selection-menu') ? {left: 0, right: 120, top: 0, bottom: 100, width: 120, height: 100} : {left: 100, right: 200, top: 100, bottom: 134, width: 100, height: 34}); }
  focus() { document.activeElement = this; }
}

class Document extends Element {
  constructor() { super('document'); this.body = new Element('body'); this.appendChild(this.body); this.activeElement = null; }
  createElement(tag) { return new Element(tag); }
  addEventListener() {}
}

const document = new Document();
const window = {innerWidth: 900, innerHeight: 700};
class MutationObserver { constructor(callback) { this.callback = callback; } observe() {} disconnect() {} }
const targetSelectionLoadState = 'ready';
const targetSelection = {check: {'node:1': '', 'guest:1': '', 'guest:2': ''}, update: {'node:1': '', 'guest:1': '', 'guest:2': ''}};
const targetSelectionConfirmed = {check: {}, update: {}};
let targetSelectionRevision = 0;
const selectionFieldState = new Map();
const selectionFieldKey = (scope, id) => `${scope}:${id}`;
const selectionStateLabel = state => state === 'only' ? 'Only' : state === 'exclude' ? 'Exclude' : 'Default';
const selectionVariantClass = element => element.dataset.selectionVariant === 'guest' ? ' guest-selection-state' : element.dataset.selectionVariant === 'node' ? ' node-selection-state' : '';
const setSelectionState = (selection, scope, id, state) => { if (state) selection[scope][id] = state; else delete selection[scope][id]; };
const saveTargetSelection = (scope, id, current, desired) => { targetSelection[scope][id] = desired; };
const paintTargetSelection = () => {};
const updateTargetSelectionIndicator = () => {};
const notice = () => {};
const selectionMenuDocumentHandlerInstalled = false;
"""

node_source = f"""
{fixture}
{listbox_source}
return {{buildNodeSelectionField, openSelectionMenu, closeSelectionMenu, cleanupSelectionMenus, document, window, targetSelection}};
"""

runner = f"""
const factory = new Function('unusedDocument', 'unusedWindow', 'unusedMutationObserver', {json.dumps(node_source)});
const api = factory(null, null, null);
const {{document, window, targetSelection}} = api;
const assert = (condition, message) => {{ if (!condition) throw new Error(message); }};
const event = {{preventDefault() {{}}, stopPropagation() {{}}}};

const nodeField = api.buildNodeSelectionField('check', 'node:1', '', 'Check all', 'node');
document.body.appendChild(nodeField);
const nodeTrigger = nodeField.querySelector('.target-selection-trigger');
const nodeMenu = nodeField.querySelector('.target-selection-menu');
assert(nodeMenu.hidden, 'new node menu must start hidden');
assert(!nodeField.classList.contains('open'), 'new node field must start closed');
assert(nodeTrigger.getAttribute('aria-expanded') === 'false', 'new node trigger must be collapsed');
nodeTrigger._rect = {{left: 140, right: 212, top: 110, bottom: 144, width: 72, height: 34}};
nodeTrigger.onclick(event);
assert(nodeField.classList.contains('open') && !nodeMenu.hidden, 'node trigger must open its menu');
assert(nodeMenu.style.left !== '0px' || nodeMenu.style.top !== '0px', 'valid menu must not be left at viewport origin');

const guestField = api.buildNodeSelectionField('check', 'guest:1', '', 'Check all', 'guest');
document.body.appendChild(guestField);
const guestTrigger = guestField.querySelector('.target-selection-trigger');
const guestMenu = guestField.querySelector('.target-selection-menu');
guestTrigger._rect = {{left: 340, right: 432, top: 500, bottom: 534, width: 92, height: 34}};
guestTrigger.onclick(event);
assert(!nodeField.classList.contains('open'), 'opening guest menu must close node menu');
assert(guestField.classList.contains('open') && !guestMenu.hidden, 'guest trigger must open its menu');
const onlyOption = guestMenu.querySelectorAll('[role="option"]')[1];
onlyOption.onclick(event);
assert(targetSelection.check['guest:1'] === 'only', 'guest option selection must use the existing save path');
assert(guestMenu.hidden && !guestField.classList.contains('open'), 'selecting an option must close the guest menu');

guestTrigger.onclick(event);
assert(guestField.classList.contains('open'), 'guest menu must reopen after closing');
guestTrigger.onclick(event);
assert(guestMenu.hidden && !guestField.classList.contains('open'), 'trigger must close an open guest menu');

const invalidField = api.buildNodeSelectionField('update', 'guest:2', '', 'Update all', 'guest');
document.body.appendChild(invalidField);
const invalidTrigger = invalidField.querySelector('.target-selection-trigger');
const invalidMenu = invalidField.querySelector('.target-selection-menu');
invalidTrigger._rect = {{left: 0, right: 0, top: 0, bottom: 0, width: 0, height: 0}};
invalidTrigger.onclick(event);
assert(invalidMenu.hidden && !invalidField.classList.contains('open'), 'invalid anchor must fail closed');

const removedField = api.buildNodeSelectionField('update', 'guest:1', '', 'Update all', 'guest');
document.body.appendChild(removedField);
const removedTrigger = removedField.querySelector('.target-selection-trigger');
removedTrigger.onclick(event);
assert(removedField.classList.contains('open'), 'removal fixture must be open before cleanup');
document.body.removeChild(removedField);
api.cleanupSelectionMenus([{{removedNodes: [removedField]}}]);
assert(removedField.querySelector('.target-selection-menu').hidden, 'removed open menu must be closed');
console.log('target selection DOM lifecycle tests: PASS');
"""

result = subprocess.run(
    ["node"],
    input=runner,
    text=True,
    capture_output=True,
    cwd=ROOT,
    check=False,
)
if result.returncode:
    print(result.stdout, end="")
    print(result.stderr, end="", file=sys.stderr)
    raise SystemExit(result.returncode)

assert "row.addEventListener('click',event=>{if(event.target.closest('.target-selection-field'))event.stopPropagation()},true)" not in server.PAGE
assert "row.addEventListener('click',event=>{if(event.target.closest('.target-selection-field'))event.stopPropagation()})" in server.PAGE
print(result.stdout, end="")
