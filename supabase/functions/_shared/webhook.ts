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

// Viene como "BCP Notificaciones <notificaciones@...>" o pelado
export function remitente(p: Payload): string | null {
  const directo =
    texto(sub(p, "FromFull")?.Email) ??
    texto(p.From) ??
    texto(p.sender) ??
    texto(p.from) ??
    texto(sub(p, "envelope")?.from) ??
    texto(sub(p, "headers")?.from);

  if (!directo) return null;
  return (directo.match(/<([^>]+)>/)?.[1] ?? directo).trim().toLowerCase();
}

export function asunto(p: Payload): string {
  return texto(p.Subject) ?? texto(p.subject) ?? texto(sub(p, "headers")?.subject) ?? "(sin asunto)";
}

export function permitido(de: string | null, extra: string | undefined, base: string[]): boolean {
  if (!de) return false;
  const lista = base.concat(
    (extra ?? "").split(",").map((s) => s.trim().toLowerCase()).filter(Boolean),
  );
  return lista.includes(de);
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
