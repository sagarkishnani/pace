// ============================================================
// Lectura del webhook del proveedor de correo entrante
//
// Cada proveedor nombra los campos distinto. Soportar los tres
// formatos cuesta poco y evita quedar casado con uno:
//
//   Postmark     TextBody / HtmlBody / FromFull.Email
//   CloudMailin  plain / html / envelope.from
//   Mailgun      body-plain / body-html / sender  (formulario)
// ============================================================

export type Payload = Record<string, unknown>;

const texto = (v: unknown): string | null =>
  typeof v === "string" && v.trim() ? v : null;

const sub = (p: Payload, k: string): Payload | undefined =>
  typeof p[k] === "object" && p[k] !== null ? (p[k] as Payload) : undefined;

export function cuerpo(p: Payload): { crudo: string; esHtml: boolean } | null {
  const plano = texto(p.TextBody) ?? texto(p.plain) ?? texto(p["body-plain"]);
  if (plano) return { crudo: plano, esHtml: false };

  const html = texto(p.HtmlBody) ?? texto(p.html) ?? texto(p["body-html"]);
  if (html) return { crudo: html, esHtml: true };

  return null;
}

const direccion = (v: unknown): string | null => {
  const s = texto(v);
  if (!s) return null;
  // Viene como "BCP Notificaciones <notificaciones@...>" o pelado
  return (s.match(/<([^>]+)>/)?.[1] ?? s).trim().toLowerCase();
};

// Devuelve TODOS los remitentes posibles, no uno.
//
// Al reenviar desde Gmail el sobre lleva tu dirección y la
// cabecera From: la del banco. Quedarse con el primero que
// aparezca hace que el reenvío se ignore en silencio, que es la
// peor forma de fallar: no hay error, simplemente no llega nada.
export function remitentes(p: Payload): string[] {
  const h = sub(p, "headers");
  const crudos = [
    sub(p, "FromFull")?.Email,
    p.From,
    p.sender,
    p.from,
    sub(p, "envelope")?.from,
    Array.isArray(h?.from) ? h?.from[0] : h?.from,
  ];
  return [...new Set(crudos.map(direccion).filter((d): d is string => d !== null))];
}

export function asunto(p: Payload): string {
  return texto(p.Subject) ?? texto(p.subject) ?? texto(sub(p, "headers")?.subject) ?? "(sin asunto)";
}

export function permitido(de: string[], extra: string | undefined, base: string[]): boolean {
  const lista = base.concat(
    (extra ?? "").split(",").map((s) => s.trim().toLowerCase()).filter(Boolean),
  );
  return de.some((d) => lista.includes(d));
}

export function autorizado(cabecera: string | null, esperado: string | undefined): boolean {
  if (!esperado) return false;
  const h = cabecera ?? "";
  if (h.startsWith("Bearer ")) return h.slice(7) === esperado;
  if (h.startsWith("Basic ")) {
    try {
      return atob(h.slice(6)).split(":").slice(1).join(":") === esperado;
    } catch {
      return false;
    }
  }
  return false;
}

export async function leerPayload(req: Request): Promise<Payload> {
  if ((req.headers.get("Content-Type") ?? "").includes("application/json")) {
    return await req.json();
  }
  const form = await req.formData();
  return Object.fromEntries([...form.entries()].map(([k, v]) => [k, String(v)]));
}
