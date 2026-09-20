import assert from "node:assert/strict";
import test from "node:test";
import {
  CATEGORIAS,
  leerMonto,
  METODOS,
  resolverCategoria,
  resolverClase,
  resolverMetodo,
} from "../supabase/functions/_shared/vocabulario.ts";
import { construirNotificacion } from "../supabase/functions/_shared/notificar.ts";

test("el menú del Atajo entra tal cual", () => {
  for (const clave of [
    "bcp_credito",
    "bcp_debito",
    "interbank_credito",
    "interbank_debito",
    "efectivo",
  ]) {
    const r = resolverMetodo(clave);
    assert.equal(r.clave, clave, clave);
    assert.equal(r.cruda, null);
  }
});

test("débito y crédito no se confunden", () => {
  assert.deepEqual(resolverMetodo("bcp_debito").metodo, { banco: "BCP", tipo: "debito" });
  assert.deepEqual(resolverMetodo("bcp_credito").metodo, { banco: "BCP", tipo: "credito" });
  assert.deepEqual(resolverMetodo("interbank_debito").metodo, {
    banco: "Interbank",
    tipo: "debito",
  });
});

test("lo que mandaba el Atajo viejo sigue entrando como crédito", () => {
  assert.equal(resolverMetodo("bcp").clave, "bcp_credito");
  assert.equal(resolverMetodo("interbank").clave, "interbank_credito");
  assert.equal(resolverMetodo("bcp").cruda, null);
});

test("un método desconocido no bota el gasto: cae al de siempre y deja rastro", () => {
  const r = resolverMetodo("scotiabank");
  assert.equal(r.clave, "interbank_credito");
  assert.equal(r.cruda, "scotiabank");
});

test("el método se normaliza: mayúsculas, espacios y guiones", () => {
  assert.equal(resolverMetodo("BCP Débito").cruda, "bcp_débito"); // la tilde no la escribe el menú
  assert.equal(resolverMetodo("  BCP_CREDITO ").clave, "bcp_credito");
  assert.equal(resolverMetodo("bcp-debito").clave, "bcp_debito");
});

test("sin método, el de siempre y sin rastro de nada crudo", () => {
  const r = resolverMetodo(undefined);
  assert.equal(r.clave, "interbank_credito");
  assert.equal(r.cruda, null);
});

test("pagar la tarjeta es un tipo aparte, fuera de la bolsa", () => {
  assert.equal(METODOS.pago_bcp.tipo, "pago_tarjeta");
  assert.equal(METODOS.pago_interbank.tipo, "pago_tarjeta");
});

test("las siete categorías canónicas y nada más", () => {
  assert.deepEqual(
    [...CATEGORIAS].sort(),
    ["comida", "hogar", "otro", "personal", "restaurante", "salud", "transporte"],
  );
});

test("una categoría desconocida entra nula y se guarda cruda", () => {
  assert.deepEqual(resolverCategoria("mascota"), { categoria: null, cruda: "mascota" });
  assert.deepEqual(resolverCategoria("Comida"), { categoria: "comida", cruda: null });
  assert.deepEqual(resolverCategoria(null), { categoria: null, cruda: null });
});

test("las clases de ingreso, y la desconocida cae a extra", () => {
  assert.equal(resolverClase("sueldo").clase, "sueldo");
  assert.equal(resolverClase("RETIRO").clase, "retiro");
  assert.equal(resolverClase("bono").clase, "extra");
  assert.equal(resolverClase("bono").cruda, "bono");
});

test("el monto aguanta lo que manda el Atajo según la región", () => {
  assert.equal(leerMonto(42.8), 42.8);
  assert.equal(leerMonto("42.80"), 42.8);
  assert.equal(leerMonto("S/ 42,80"), 42.8);
  assert.equal(leerMonto("0"), null);
  assert.equal(leerMonto(-5), null);
  assert.equal(leerMonto("hola"), null);
  assert.equal(leerMonto(null), null);
});

// ------------------------------------------------------------
// Notificaciones
// ------------------------------------------------------------
const AVISO = { titulo: "🔴 A este ritmo no llegas", cuerpo: "Día 12 de 30", estado: "rojo" };

test("ntfy: el título va en header y sin emoji, que un header no aguanta", () => {
  const { init } = construirNotificacion("https://ntfy.sh/pace-sagar", AVISO);
  const h = init.headers as Record<string, string>;
  assert.equal(h.Title, "A este ritmo no llegas");
  assert.equal(h.Tags, "rotating_light");
  assert.equal(h.Priority, "high");
  assert.equal(init.body, "Día 12 de 30");
});

test("telegram: el chat_id sale de la URL y pasa al cuerpo", () => {
  const { url, init } = construirNotificacion(
    "https://api.telegram.org/bot123:ABC/sendMessage?chat_id=987",
    AVISO,
  );
  assert.ok(!url.includes("chat_id"));
  const b = JSON.parse(init.body as string);
  assert.equal(b.chat_id, "987");
  assert.ok(b.text.startsWith("🔴 A este ritmo no llegas"));
});

test("un webhook cualquiera recibe el JSON genérico", () => {
  const { init } = construirNotificacion("https://ejemplo.com/hook", AVISO);
  assert.deepEqual(JSON.parse(init.body as string), {
    titulo: AVISO.titulo,
    cuerpo: AVISO.cuerpo,
    estado: "rojo",
  });
});
