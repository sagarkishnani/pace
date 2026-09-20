// ============================================================
// Salida de las alertas
//
// No hay app propia ni la va a haber, así que la notificación
// sale por un webhook y el proveedor lo eliges tú. Un solo
// secret —ALERTA_WEBHOOK_URL— y la forma del payload se deduce
// del dominio.
//
//   ntfy.sh      cuerpo en texto plano, título y tags por header
//   Telegram     JSON {chat_id, text}; el chat_id va en la URL
//   Pushcut      JSON {title, text}
//   Discord      JSON {content}
//   cualquiera   JSON {titulo, cuerpo, estado}
//
// Deducir por dominio y no por un segundo secret de "tipo" evita
// el estado imposible de tener la URL de uno y el formato de
// otro. Si el proveedor no está en la lista recibe el JSON
// genérico, que es lo que aceptan casi todos los "custom
// webhook".
// ============================================================

export type Aviso = {
  titulo: string;
  cuerpo: string;
  estado: string; // 'verde' | 'ambar' | 'rojo'
};

// ntfy pone el título en un header HTTP, y un header con emoji
// no sobrevive el viaje. Los iconos van aparte, como tags.
const TAGS: Record<string, string> = {
  verde: "green_circle",
  ambar: "orange_circle",
  rojo: "rotating_light",
};

const sinEmoji = (s: string) =>
  s.replace(/[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}]/gu, "").trim();

export function construirNotificacion(
  destino: string,
  aviso: Aviso,
): { url: string; init: RequestInit } {
  const u = new URL(destino);
  const host = u.hostname.toLowerCase();
  const json = (body: unknown): RequestInit => ({
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  });

  if (host === "ntfy.sh" || host.endsWith(".ntfy.sh")) {
    return {
      url: destino,
      init: {
        method: "POST",
        headers: {
          "Content-Type": "text/plain; charset=utf-8",
          "Title": sinEmoji(aviso.titulo),
          "Tags": TAGS[aviso.estado] ?? "moneybag",
          "Priority": aviso.estado === "rojo" ? "high" : "default",
        },
        body: aviso.cuerpo,
      },
    };
  }

  if (host === "api.telegram.org") {
    // El chat_id viaja en la query para no gastar un secret más
    const chat = u.searchParams.get("chat_id");
    u.searchParams.delete("chat_id");
    return {
      url: u.toString(),
      init: json({
        chat_id: chat,
        text: `${aviso.titulo}\n\n${aviso.cuerpo}`,
        disable_web_page_preview: true,
      }),
    };
  }

  if (host === "api.pushcut.io") {
    return { url: destino, init: json({ title: aviso.titulo, text: aviso.cuerpo }) };
  }

  if (host === "discord.com" || host === "discordapp.com") {
    return {
      url: destino,
      init: json({ content: `**${aviso.titulo}**\n${aviso.cuerpo}` }),
    };
  }

  return {
    url: destino,
    init: json({ titulo: aviso.titulo, cuerpo: aviso.cuerpo, estado: aviso.estado }),
  };
}

// Manda el aviso. No lanza: una alerta que no salió no puede
// tumbar el registro de un gasto, que es lo que de verdad
// importa guardar.
export async function enviarAviso(
  destino: string | undefined,
  aviso: Aviso,
): Promise<{ enviado: boolean; detalle?: string }> {
  if (!destino) return { enviado: false, detalle: "Sin ALERTA_WEBHOOK_URL" };

  try {
    const { url, init } = construirNotificacion(destino, aviso);
    const r = await fetch(url, init);
    if (!r.ok) {
      const t = await r.text().catch(() => "");
      return { enviado: false, detalle: `${r.status} ${t.slice(0, 200)}` };
    }
    return { enviado: true };
  } catch (e) {
    return { enviado: false, detalle: String(e) };
  }
}
