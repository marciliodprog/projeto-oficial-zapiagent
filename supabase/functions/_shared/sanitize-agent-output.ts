// Remove vazamentos de tool call que alguns modelos (notadamente Gemini 3
// preview) emitem como texto livre em vez de preencher `tool_calls[]`.
// Padrões vistos em produção:
//   funcall:default_api:add_lead_note{content:...}
//   default_api.apply_tags({...})
//   ```tool_code\nprint(default_api.foo(...))\n```
//   {"name":"add_lead_note","arguments":{...}}
//
// Uso: `const { text, leaked } = sanitizeAgentOutput(raw)`

const PATTERNS: RegExp[] = [
  // funcall:namespace:tool_name{...} (com chaves balanceadas simples)
  /funcall\s*:\s*[a-z_][\w.]*\s*:\s*[a-z_][\w]*\s*\{[\s\S]*?\}/gi,
  // default_api.tool_name(...) ou default_api:tool_name{...}
  /default_api\s*[.:]\s*[a-z_][\w]*\s*[({][\s\S]*?[)}]/gi,
  // Blocos ```tool_code ... ``` ou ```tool ... ```
  /```tool(?:_code)?[\s\S]*?```/gi,
  // print(default_api.xxx(...))
  /print\s*\(\s*default_api[\s\S]*?\)\s*\)?/gi,
  // JSON solto tipo {"name":"tool_x","arguments":{...}}
  /\{\s*"name"\s*:\s*"[a-z_][\w]*"\s*,\s*"arguments"\s*:\s*\{[\s\S]*?\}\s*\}/gi,
];

export interface SanitizeResult {
  text: string;
  leaked: boolean;
  removed: string[];
}

export function sanitizeAgentOutput(input: string | null | undefined): SanitizeResult {
  const original = String(input ?? '');
  if (!original) return { text: '', leaked: false, removed: [] };

  let text = original;
  const removed: string[] = [];

  for (const re of PATTERNS) {
    text = text.replace(re, (match) => {
      removed.push(match.slice(0, 200));
      return '';
    });
  }

  // Limpa quebras de linha órfãs / espaços duplicados criados pela remoção.
  text = text
    .replace(/[ \t]{2,}/g, ' ')
    .replace(/\n{3,}/g, '\n\n')
    .trim();

  return { text, leaked: removed.length > 0, removed };
}
