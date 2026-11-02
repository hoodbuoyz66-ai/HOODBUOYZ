import { createServer } from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = fileURLToPath(new URL('./outputs/', import.meta.url));
const types = { '.html':'text/html; charset=utf-8','.css':'text/css; charset=utf-8','.js':'text/javascript; charset=utf-8','.xml':'application/xml; charset=utf-8','.svg':'image/svg+xml','.png':'image/png','.jpg':'image/jpeg','.jpeg':'image/jpeg','.webp':'image/webp' };
try {
  const envText = await readFile(new URL('./.env', import.meta.url), 'utf8');
  for (const line of envText.split(/\r?\n/)) {
    const entry = line.match(/^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$/);
    if (!entry || entry[1] in process.env) continue;
    process.env[entry[1]] = entry[2].replace(/^(['"])(.*)\1$/, '$2');
  }
} catch (error) { if (error.code !== 'ENOENT') throw error; }
function browserSupabaseConfig() {
  let supabaseUrl = (process.env.SUPABASE_URL || '').trim();
  const apiKey = (process.env.SUPABASE_ANON_KEY || '').trim();
  if (!supabaseUrl || /YOUR_PROJECT|YOUR_|example\.com/i.test(supabaseUrl)) {
    return { supabaseUrl:'', supabaseAnonKey:'', configError:'Replace the template SUPABASE_URL in the project .env with your actual Supabase Project URL.' };
  }
  try {
    const parsed = new URL(supabaseUrl);
    if (parsed.protocol !== 'https:' || !parsed.hostname || parsed.username || parsed.password || parsed.search || parsed.hash) throw new Error('invalid URL');
    const path = parsed.pathname.replace(/\/+$/, '');
    // A project API endpoint is sometimes pasted instead of the root Project URL.
    // Supabase JS appends /auth/v1, /rest/v1, etc. itself, so pass the origin only.
    if (path && !/^\/(?:rest|auth|storage|functions|realtime)\/v1$/i.test(path)) {
      return { supabaseUrl:'', supabaseAnonKey:'', configError:'SUPABASE_URL has an unsupported path. Use the Supabase project URL or its standard API endpoint URL.' };
    }
    supabaseUrl = parsed.origin;
  } catch {
    return { supabaseUrl:'', supabaseAnonKey:'', configError:'SUPABASE_URL must be your valid HTTPS Supabase Project URL.' };
  }
  if (!apiKey || /YOUR_|PLACEHOLDER/i.test(apiKey)) {
    return { supabaseUrl:'', supabaseAnonKey:'', configError:'Replace the template SUPABASE_ANON_KEY in .env with your browser-safe publishable key (or legacy anon key).' };
  }
  if (apiKey.startsWith('sb_secret_')) {
    return { supabaseUrl:'', supabaseAnonKey:'', configError:'A Supabase secret key cannot be used by the browser. Set the publishable key instead.' };
  }
  if (apiKey.startsWith('sb_publishable_')) return { supabaseUrl, supabaseAnonKey:apiKey };
  if (apiKey.startsWith('eyJ')) {
    try {
      const payload = JSON.parse(Buffer.from(apiKey.split('.')[1] || '', 'base64url').toString('utf8'));
      if (payload.role === 'anon') return { supabaseUrl, supabaseAnonKey:apiKey };
    } catch { /* Invalid legacy key: report a safe configuration message below. */ }
  }
  return { supabaseUrl:'', supabaseAnonKey:'', configError:'SUPABASE_ANON_KEY must be a publishable key or a legacy anon key. Secret/service-role keys are not accepted.' };
}
const server = createServer(async (req, res) => {
  const url = new URL(req.url || '/', 'http://localhost');
  if (url.pathname === '/api/config') {
    res.writeHead(200, { 'content-type':'application/json; charset=utf-8', 'cache-control':'no-store', 'x-content-type-options':'nosniff' });
    res.end(JSON.stringify(browserSupabaseConfig())); return;
  }
  let pathname = decodeURIComponent(url.pathname);
  if (pathname === '/admin' || pathname === '/admin/') pathname = '/admin.html';
  if (pathname === '/') pathname = '/index.html';
  const target = normalize(join(root, pathname.replace(/^[/\\]+/, '')));
  if (!target.startsWith(root)) { res.writeHead(403); res.end('Forbidden'); return; }
  try {
    const info = await stat(target); if (!info.isFile()) throw new Error('Not a file');
    res.writeHead(200, { 'content-type':types[extname(target)] || 'application/octet-stream', 'x-content-type-options':'nosniff', 'referrer-policy':'strict-origin-when-cross-origin' });
    res.end(await readFile(target));
  } catch { res.writeHead(404, { 'content-type':'text/plain; charset=utf-8' }); res.end('Not found'); }
});
const port = Number(process.env.PORT || 4173);
server.listen(port, '0.0.0.0', () => console.log(`HOOD BUOYZ running on port ${port}`));
export { server };
