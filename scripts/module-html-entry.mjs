import { defaultTreeAdapter, parse } from '../.cache/module-html-runtime/node_modules/parse5/dist/index.js';

const MAX_NODES = 30000;
const MAX_DEPTH = 128;
export function parseModuleHtml(text) {
  if (typeof text !== 'string' || text.length > 2 * 1024 * 1024) throw new Error('HTML input is too large');
  let nodes = 0;
  const count = () => { if (++nodes > MAX_NODES) throw new Error('HTML tree is too large'); };
  const checkDepth = parent => {
    let depth = 0;
    while (parent) {
      if (++depth > MAX_DEPTH) throw new Error('HTML nesting is too deep');
      parent = parent.parentNode;
    }
  };
  const adapter = {
    ...defaultTreeAdapter,
    createElement(...args) { count(); return defaultTreeAdapter.createElement(...args); },
    createTextNode(...args) { count(); return defaultTreeAdapter.createTextNode(...args); },
    createCommentNode(...args) { count(); return defaultTreeAdapter.createCommentNode(...args); },
    appendChild(parent, child) { checkDepth(parent); defaultTreeAdapter.appendChild(parent, child); },
    insertBefore(parent, child, reference) {
      checkDepth(parent);
      defaultTreeAdapter.insertBefore(parent, child, reference);
    },
    insertText(parent, text) { count(); checkDepth(parent); defaultTreeAdapter.insertText(parent, text); },
    insertTextBefore(parent, text, reference) {
      count();
      checkDepth(parent);
      defaultTreeAdapter.insertTextBefore(parent, text, reference);
    }
  };
  const document = parse(text, { treeAdapter: adapter, scriptingEnabled: false });
  function convert(node, depth) {
    if (depth > MAX_DEPTH) throw new Error('HTML nesting is too deep');
    const attrs = Object.create(null);
    for (const attr of node.attrs || []) attrs[attr.name] = attr.value;
    return {
      tag: node.tagName || '',
      attrs,
      text: node.nodeName === '#text' ? node.value : '',
      children: (node.childNodes || []).filter(child => child.tagName || child.nodeName === '#text')
        .map(child => convert(child, depth + 1))
    };
  }
  return convert(document, 0);
}
