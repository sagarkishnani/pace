// ============================================================
// Lo que repiten los cuatro endpoints
//
// El panel se sirve desde otro origen (un .pages.dev, o el
// archivo abierto local), así que las respuestas que lee el
// navegador llevan CORS. Es seguro con `*` porque la llave es el
// token del header: sin credenciales de cookie, un origen
// cualquiera no gana nada pudiendo llamar.
// ============================================================

export const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

export const json = (body: unknown, status = 200, cors = false) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...(cors ? CORS : {}),
    },
  });

export const preflight = () => new Response(null, { status: 204, headers: CORS });

// Bearer siempre; `?token=` solo donde hace falta abrir un enlace
// a mano (el panel, el cron). Los endpoints de los Atajos no lo
// aceptan: un token en la URL termina en los logs del gateway y
// en el historial del navegador, y ahí no gana nada.
export function tokenDe(req: Request, enQuery = false): string | null {
  const h = req.headers.get("Authorization");
  if (h?.startsWith("Bearer ")) return h.slice(7).trim() || null;
  return enQuery ? new URL(req.url).searchParams.get("token") : null;
}

// Comparación de largo constante. El token es corto y el endpoint
// es público; no cuesta nada cerrarle la puerta al ataque de
// tiempo.
export function tokenValido(dado: string | null, esperado: string | undefined): boolean {
  if (!dado || !esperado || dado.length !== esperado.length) return false;
  let dif = 0;
  for (let i = 0; i < dado.length; i++) dif |= dado.charCodeAt(i) ^ esperado.charCodeAt(i);
  return dif === 0;
}

// Deno tumba las promesas pendientes al responder. waitUntil las
// mantiene vivas: así la notificación sale sin que el Atajo
// espere el viaje de ida y vuelta al webhook. El gesto tiene un
// presupuesto de cinco segundos y no se le va a gastar en esto.
export function enSegundoPlano(p: Promise<unknown>): void {
  const rt = (globalThis as { EdgeRuntime?: { waitUntil?: (p: Promise<unknown>) => void } })
    .EdgeRuntime;
  if (rt?.waitUntil) rt.waitUntil(p);
  else p.catch(() => {});
}
