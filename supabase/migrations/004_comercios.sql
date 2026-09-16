-- ============================================================
-- Catálogo de comercios
--
-- El patrón se busca como substring del texto sucio del banco, y
-- gana el más largo. Por eso 'DIDI FOOD' convive con 'DIDI' sin
-- pisarse: el delivery no termina contado como transporte.
--
-- Esto es un punto de partida, no una verdad. Cuando un comercio
-- caiga en la categoría equivocada, corrige acá y listo.
-- ============================================================

insert into comercios (patron, nombre, categoria) values
  -- Comida: mercado y bodega
  ('PVEA',            'Plaza Vea',     'comida'),
  ('PLAZA VEA',       'Plaza Vea',     'comida'),
  ('TOTTUS',          'Tottus',        'comida'),
  ('WONG',            'Wong',          'comida'),
  ('METRO',           'Metro',         'comida'),
  ('VIVANDA',         'Vivanda',       'comida'),
  ('MAKRO',           'Makro',         'comida'),
  ('MASS',            'Mass',          'comida'),
  ('OXXO',            'Oxxo',          'comida'),
  ('TAMBO',           'Tambo',         'comida'),

  -- Restaurante: salir a comer y delivery
  ('RAPPI',           'Rappi',         'restaurante'),
  ('PEDIDOSYA',       'PedidosYa',     'restaurante'),
  ('DIDI FOOD',       'Didi Food',     'restaurante'),
  ('BEMBOS',          'Bembos',        'restaurante'),
  ('KFC',             'KFC',           'restaurante'),
  ('POPEYES',         'Popeyes',       'restaurante'),
  ('PIZZA HUT',       'Pizza Hut',     'restaurante'),
  ('PAPA JOHNS',      'Papa Johns',    'restaurante'),
  ('NORKYS',          'Norkys',        'restaurante'),
  ('CHINA WOK',       'China Wok',     'restaurante'),
  ('STARBUCKS',       'Starbucks',     'restaurante'),
  ('JUAN VALDEZ',     'Juan Valdez',   'restaurante'),
  ('TANTA',           'Tanta',         'restaurante'),
  ('LA LUCHA',        'La Lucha',      'restaurante'),

  -- Transporte
  ('UBER',            'Uber',          'transporte'),
  ('CABIFY',          'Cabify',        'transporte'),
  ('INDRIVE',         'inDrive',       'transporte'),
  ('BEAT',            'Beat',          'transporte'),
  ('DIDI',            'Didi',          'transporte'),
  ('PRIMAX',          'Primax',        'transporte'),
  ('REPSOL',          'Repsol',        'transporte'),
  ('PETROPERU',       'Petroperú',     'transporte'),
  ('PECSA',           'Pecsa',         'transporte'),
  ('RUTAS DE LIMA',   'Peaje',         'transporte'),
  ('PEAJE',           'Peaje',         'transporte'),

  -- Salud
  ('INKAFARMA',       'Inkafarma',     'salud'),
  ('MIFARMA',         'Mifarma',       'salud'),
  ('BOTICAS',         'Boticas',       'salud'),
  ('FARMACIA',        'Farmacia',      'salud'),
  ('CLINICA',         'Clínica',       'salud'),
  ('LABORATORIO',     'Laboratorio',   'salud'),

  -- Hogar
  ('SODIMAC',         'Sodimac',       'hogar'),
  ('PROMART',         'Promart',       'hogar'),
  ('MAESTRO',         'Maestro',       'hogar'),
  ('ACE HOME',        'Ace Home',      'hogar'),
  ('CASAIDEAS',       'Casaideas',     'hogar'),

  -- Personal
  ('SAGA FALABELLA',  'Saga Falabella','personal'),
  ('FALABELLA',       'Falabella',     'personal'),
  ('RIPLEY',          'Ripley',        'personal'),
  ('OECHSLE',         'Oechsle',       'personal'),
  ('ZARA',            'Zara',          'personal'),
  ('H&M',             'H&M',           'personal'),
  ('TOPITOP',         'Topitop',       'personal'),
  ('SMART FIT',       'Smart Fit',     'personal'),
  ('GOLDS GYM',       'Golds Gym',     'personal')

on conflict (patron) do nothing;
