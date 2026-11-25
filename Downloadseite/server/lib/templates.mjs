// A tiny template language for the HTML pages (escaped by default):
//   {{name}} {{a.b}}          value, HTML-escaped
//   {{#name}}…{{/name}}       block if the value is truthy
//   {{^name}}…{{/name}}       block if the value is falsy (an empty list counts as falsy)
//   {{#list}}…{{/list}}       block once per object in the list: its fields first, then the outer values
//   {{> partial}}             another template from public/_partials
//   {{@asset /assets/x.css}}  the asset's URL with its content hash (?v=…)
//   {{@json name}}            the value as JSON, safe inside <script type="application/ld+json">

const TAG = /\{\{\s*([#^/>@]?)\s*([^}]*?)\s*\}\}/g;

export function escapeHtml(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

/** JSON for a <script> element: nothing in it can end the element or start markup. */
export function jsonForScript(value) {
  return JSON.stringify(value ?? null).replace(/[<>&\u2028\u2029]/g, (c) => `\\u${c.charCodeAt(0).toString(16).padStart(4, '0')}`);
}

export function compile(source, name = 'template') {
  const root = { children: [] };
  const stack = [root];
  let last = 0;
  TAG.lastIndex = 0;
  for (let match = TAG.exec(source); match; match = TAG.exec(source)) {
    const top = stack[stack.length - 1];
    if (match.index > last) top.children.push({ type: 'text', value: source.slice(last, match.index) });
    last = TAG.lastIndex;
    const [, sigil, body] = match;
    if (!body) throw new Error(`${name}: leeres {{ }}`);
    if (sigil === '#' || sigil === '^') {
      const node = { type: 'section', key: body, inverted: sigil === '^', children: [] };
      top.children.push(node);
      stack.push(node);
    } else if (sigil === '/') {
      const open = stack.pop();
      if (stack.length === 0 || open.key !== body) throw new Error(`${name}: {{/${body}}} passt zu keinem Block.`);
    } else if (sigil === '>') {
      top.children.push({ type: 'partial', name: body });
    } else if (sigil === '@') {
      const [fn, arg] = body.split(/\s+/);
      if (fn === 'asset' && arg) top.children.push({ type: 'asset', path: arg });
      else if (fn === 'json' && arg) top.children.push({ type: 'json', key: arg });
      else throw new Error(`${name}: unbekannte Funktion {{@${body}}}.`);
    } else {
      top.children.push({ type: 'value', key: body });
    }
  }
  if (stack.length !== 1) throw new Error(`${name}: {{#${stack[stack.length - 1].key}}} wird nicht geschlossen.`);
  if (last < source.length) root.children.push({ type: 'text', value: source.slice(last) });
  return root.children;
}

function lookup(context, key) {
  let value = context;
  for (const part of key.split('.')) {
    if (value === null || value === undefined) return undefined;
    value = value[part];
  }
  return value;
}

/** The context inside a list block: the item's own fields, and everything else from outside. */
function scope(context, item) {
  if (item === null || typeof item !== 'object') return context;
  return Object.create(context ?? null, Object.getOwnPropertyDescriptors(item));
}

/**
 * @param {Array} nodes compiled template
 * @param {object} context values
 * @param {{partials: Map<string, Array>, asset: (path: string) => string}} env
 */
export function render(nodes, context, env, depth = 0) {
  if (depth > 10) throw new Error('Partials sind zu tief verschachtelt.');
  let out = '';
  for (const node of nodes) {
    switch (node.type) {
      case 'text':
        out += node.value;
        break;
      case 'value':
        out += escapeHtml(lookup(context, node.key));
        break;
      case 'section': {
        const value = lookup(context, node.key);
        if (Array.isArray(value) && !node.inverted) {
          for (const item of value) out += render(node.children, scope(context, item), env, depth);
          break;
        }
        const truthy = Array.isArray(value) ? value.length > 0 : Boolean(value);
        if (truthy !== node.inverted) out += render(node.children, context, env, depth);
        break;
      }
      case 'partial': {
        const partial = env.partials.get(node.name);
        if (!partial) throw new Error(`Partial "${node.name}" fehlt.`);
        out += render(partial, context, env, depth + 1);
        break;
      }
      case 'asset':
        out += escapeHtml(env.asset(node.path));
        break;
      case 'json':
        out += jsonForScript(lookup(context, node.key));
        break;
      default:
        throw new Error(`Unbekannter Knoten ${node.type}`);
    }
  }
  return out;
}
