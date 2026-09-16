// ============================================================
// Normalización y extracción de campos de los correos
//
// Todo se compara sin tildes a propósito. El propio BCP advierte
// en sus correos que "si este correo omite vocales, tildes, letras
// ñ o éstas son cambiadas por otros caracteres" — así que buscar
// "Código" literal es apostar a que el render salió bien.
// ============================================================

export function sinTildes(s: string): string {
  return s.normalize("NFD").replace(/[̀-ͯ]/g, "");
}

// HTML → texto plano con los saltos donde importan.
// Las celdas de tabla se separan con "|" porque los correos de
// banco ponen etiqueta y valor en celdas contiguas.
export function aTexto(cuerpo: string, esHtml = true): string {
  let t = cuerpo;

  if (esHtml) {
    t = t
      .replace(/<(script|style)[\s\S]*?<\/\1>/gi, " ")
      .replace(/<br\s*\/?>/gi, "\n")
      .replace(/<\/(p|div|tr|h[1-6]|li)>/gi, "\n")
      .replace(/<\/t[dh]>/gi, " | ")
      .replace(/<[^>]+>/g, " ");
  }

  t = t
    .replace(/&nbsp;/gi, " ")
    .replace(/&amp;/gi, "&")
    .replace(/&#(\d+);/g, (_, d) => String.fromCharCode(Number(d)))
    .replace(/&[a-z]+;/gi, " ");

  return sinTildes(t)
    .split("\n")
    .map((l) => l.replace(/[ \t ]+/g, " ").trim())
    .filter(Boolean)
    .join("\n");
}

const escapar = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

// Busca "Etiqueta: valor", "Etiqueta | valor" o la etiqueta con el
// valor en la línea siguiente. Los tres layouts aparecen en los
// cuatro correos.
export function campo(txt: string, etiqueta: string): string | null {
  const re = new RegExp(
    escapar(sinTildes(etiqueta)).replace(/\s+/g, "\\s+") + "\\s*[:|*]*\\s*([^\\n|]+)",
    "i",
  );
  const m = txt.match(re);
  return m ? m[1].trim() || null : null;
}

export function campoRe(txt: string, re: RegExp): string | null {
  const m = txt.match(re);
  return m ? m[1].trim() || null : null;
}

export function monto(s: string | null): number | null {
  if (!s) return null;
  const m = s.match(/(?:S\/|US\$|\$)?\s*([\d][\d.,]*)/);
  if (!m) return null;
  const n = Number(m[1].replace(/,/g, ""));
  return Number.isFinite(n) && n > 0 ? n : null;
}

export function moneda(s: string | null): string {
  return s && /US\$|USD/i.test(s) ? "USD" : "PEN";
}

const MESES: Record<string, number> = {
  ene: 1, feb: 2, mar: 3, abr: 4, may: 5, jun: 6,
  jul: 7, ago: 8, sep: 9, set: 9, oct: 10, nov: 11, dic: 12,
};

// Los cuatro correos escriben la fecha distinto:
//   "05 de setiembre de 2026 - 05:15 PM"   BCP
//   "15 septiembre 2026 - 11:26 p. m."     Yape P2P
//   "29 Ago, 2026 - 02:56 pm"              Yape servicios
//   "02 Sep 2026 11:57 AM"                 Plin
// Y "setiembre" convive con "septiembre", que es como se escribe acá.
export function fecha(s: string | null): string | null {
  if (!s) return null;
  const t = sinTildes(s).toLowerCase();

  const f = t.match(/(\d{1,2})\s*(?:de\s+)?([a-z]{3})[a-z]*\.?,?\s*(?:de\s+)?(\d{4})/);
  if (!f) return null;

  const mes = MESES[f[2]];
  if (!mes) return null;

  let hora = 0;
  let min = 0;
  const h = t.match(/(\d{1,2}):(\d{2})\s*(?:([ap])\s*\.?\s*\.?\s*m)?/);
  if (h) {
    hora = Number(h[1]);
    min = Number(h[2]);
    if (h[3]) {
      hora = hora % 12;
      if (h[3] === "p") hora += 12;
    }
  }

  // Perú es UTC-5 todo el año, sin horario de verano.
  return new Date(Date.UTC(Number(f[3]), mes - 1, Number(f[1]), hora + 5, min)).toISOString();
}

export async function hash(s: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
