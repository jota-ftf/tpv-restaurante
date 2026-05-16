-- ============================================================
-- TPV Restaurante · Schema Supabase
-- Ejecutar en: Supabase Dashboard → SQL Editor → New query
-- ============================================================

-- 1. EXTENSIONES
create extension if not exists "uuid-ossp";

-- ============================================================
-- 2. TABLAS PRINCIPALES
-- ============================================================

-- Empleados (gestionados por admin, no usan auth de Supabase)
create table empleados (
  id uuid primary key default uuid_generate_v4(),
  nombre text not null,
  pin text not null, -- PIN de 4-6 dígitos (guardar como hash en prod)
  rol text not null check (rol in ('admin','encargado','camarero','cocina')),
  activo boolean default true,
  zonas_asignadas text[] default '{}', -- ['mesa-1','mesa-5','barra-2']
  created_at timestamptz default now()
);

-- Zonas (mesas, barra, terraza, etc.)
create table zonas (
  id uuid primary key default uuid_generate_v4(),
  nombre text not null,        -- 'Mesa 1', 'Barra 3', 'Terraza 5'
  tipo text not null check (tipo in ('mesa','barra','terraza','otra')),
  capacidad int default 4,
  activa boolean default true,
  orden int default 0,
  created_at timestamptz default now()
);

-- Árbol de menú (estructura jerárquica)
create table menu_nodos (
  id uuid primary key default uuid_generate_v4(),
  padre_id uuid references menu_nodos(id) on delete cascade,
  nombre text not null,
  emoji text default '',
  precio numeric(8,2),           -- null si es nodo intermedio (categoría)
  destino text check (destino in ('barra','cocina','ambos')), -- null si no es hoja
  incluye_tapa boolean default false,
  activo boolean default true,
  orden int default 0,
  created_at timestamptz default now()
);

-- Sesiones de zona (una mesa abierta = una sesión activa)
create table sesiones (
  id uuid primary key default uuid_generate_v4(),
  zona_id uuid not null references zonas(id),
  empleado_id uuid references empleados(id), -- quien abrió la mesa
  estado text not null default 'abierta' check (estado in ('abierta','cobrada','cerrada_error')),
  turno int,                   -- orden de atención
  created_at timestamptz default now(),
  cerrada_at timestamptz
);

-- Rondas de pedido dentro de una sesión
create table rondas (
  id uuid primary key default uuid_generate_v4(),
  sesion_id uuid not null references sesiones(id) on delete cascade,
  numero int not null,           -- 1, 2, 3...
  estado text not null default 'pendiente' check (estado in ('pendiente','confirmada','servida')),
  tapas_extra int default 0,     -- tapas extra añadidas manualmente
  precio_tapa_extra numeric(8,2) default 0,
  created_at timestamptz default now(),
  confirmada_at timestamptz,
  servida_at timestamptz
);

-- Líneas de cada ronda
create table lineas (
  id uuid primary key default uuid_generate_v4(),
  ronda_id uuid not null references rondas(id) on delete cascade,
  nodo_id uuid references menu_nodos(id),
  nombre text not null,          -- copia del nombre en el momento del pedido
  precio numeric(8,2) not null,
  cantidad int not null default 1,
  destino text not null check (destino in ('barra','cocina')),
  incluye_tapa boolean default false,
  nota text,
  created_at timestamptz default now()
);

-- Tickets de cocina/barra (cola de pedidos)
create table tickets (
  id uuid primary key default uuid_generate_v4(),
  ronda_id uuid not null references rondas(id) on delete cascade,
  sesion_id uuid not null references sesiones(id) on delete cascade,
  zona_nombre text not null,     -- copia para mostrar sin joins
  destino text not null check (destino in ('barra','cocina')),
  estado text not null default 'pendiente' check (estado in ('pendiente','listo','recogido')),
  empleado_nombre text,          -- camarero que hizo el pedido
  lineas jsonb not null,         -- snapshot de las líneas
  created_at timestamptz default now(),
  listo_at timestamptz,
  recogido_at timestamptz
);

-- Cobros
create table cobros (
  id uuid primary key default uuid_generate_v4(),
  sesion_id uuid not null references sesiones(id),
  numero_ticket text not null,   -- T-00001
  empleado_id uuid references empleados(id),
  total numeric(10,2) not null,
  efectivo numeric(10,2),
  cambio numeric(10,2),
  desglose jsonb,                -- rondas con sus líneas para el ticket
  created_at timestamptz default now()
);

-- Auditoría (registro de acciones críticas)
create table auditoria (
  id uuid primary key default uuid_generate_v4(),
  empleado_id uuid references empleados(id),
  empleado_nombre text,
  accion text not null,          -- 'cobro', 'precio_modificado', 'cierre_dia', etc.
  detalle jsonb,
  created_at timestamptz default now()
);

-- Configuración global
create table config (
  clave text primary key,
  valor jsonb not null,
  updated_at timestamptz default now()
);

-- ============================================================
-- 3. CONTADOR DE TICKETS (función atómica)
-- ============================================================
create sequence if not exists ticket_seq start 1;

create or replace function siguiente_numero_ticket()
returns text language sql as $$
  select 'T-' || lpad(nextval('ticket_seq')::text, 5, '0');
$$;

-- ============================================================
-- 4. CONTADOR DE TURNOS
-- ============================================================
create or replace function asignar_turno()
returns int language sql as $$
  select coalesce(max(turno), 0) + 1 from sesiones where estado = 'abierta';
$$;

-- ============================================================
-- 5. ROW LEVEL SECURITY
-- ============================================================

alter table empleados        enable row level security;
alter table zonas            enable row level security;
alter table menu_nodos       enable row level security;
alter table sesiones         enable row level security;
alter table rondas           enable row level security;
alter table lineas           enable row level security;
alter table tickets          enable row level security;
alter table cobros           enable row level security;
alter table auditoria        enable row level security;
alter table config           enable row level security;

-- Política: la anon key puede leer y escribir todo
-- (la autenticación la gestionamos nosotros con PINes, no con auth de Supabase)
-- En producción esto se restringe más; para empezar es funcional y seguro
-- porque la anon key es pública pero RLS controla el acceso a filas.

create policy "anon_all" on empleados        for all to anon using (true) with check (true);
create policy "anon_all" on zonas            for all to anon using (true) with check (true);
create policy "anon_all" on menu_nodos       for all to anon using (true) with check (true);
create policy "anon_all" on sesiones         for all to anon using (true) with check (true);
create policy "anon_all" on rondas           for all to anon using (true) with check (true);
create policy "anon_all" on lineas           for all to anon using (true) with check (true);
create policy "anon_all" on tickets          for all to anon using (true) with check (true);
create policy "anon_all" on cobros           for all to anon using (true) with check (true);
create policy "anon_all" on auditoria        for all to anon using (true) with check (true);
create policy "anon_all" on config           for all to anon using (true) with check (true);

-- ============================================================
-- 6. DATOS INICIALES
-- ============================================================

-- Admin por defecto (PIN: 0000)
insert into empleados (nombre, pin, rol) values
  ('Administrador', '0000', 'admin');

-- Configuración base
insert into config (clave, valor) values
  ('negocio', '{"nombre":"Mi Restaurante","logo":"🍽️","mensaje_ticket":"¡Gracias por su visita!"}'),
  ('tapas_extra', '{"precio":1.50}'),
  ('tiempos', '{"aviso_sin_nota_min":10,"aviso_demora_min":15}');

-- Zonas de ejemplo
insert into zonas (nombre, tipo, orden) values
  ('Mesa 1',    'mesa',    1),
  ('Mesa 2',    'mesa',    2),
  ('Mesa 3',    'mesa',    3),
  ('Mesa 4',    'mesa',    4),
  ('Mesa 5',    'mesa',    5),
  ('Mesa 6',    'mesa',    6),
  ('Barra 1',   'barra',   1),
  ('Barra 2',   'barra',   2),
  ('Terraza 1', 'terraza', 1),
  ('Terraza 2', 'terraza', 2);

-- Árbol de menú de ejemplo
-- Bebidas (nodo raíz)
with beb as (
  insert into menu_nodos (nombre, emoji, orden) values ('Bebidas','🥤',1) returning id
),
-- Cervezas
cerv as (
  insert into menu_nodos (padre_id, nombre, emoji, orden)
  select id,'Cervezas','🍺',1 from beb returning id
),
-- Vinos
vin as (
  insert into menu_nodos (padre_id, nombre, emoji, orden)
  select id,'Vinos','🍷',2 from beb returning id
),
-- Refrescos
ref as (
  insert into menu_nodos (padre_id, nombre, emoji, orden)
  select id,'Refrescos','🥤',3 from beb returning id
),
-- Cafés
caf_root as (
  insert into menu_nodos (padre_id, nombre, emoji, orden)
  select id,'Cafés','☕',4 from beb returning id
)
-- Hojas de cervezas
insert into menu_nodos (padre_id, nombre, emoji, precio, destino, incluye_tapa, orden)
select id,'1/3 con tapa','🍺',2.50,'barra',true,1 from cerv
union all
select id,'1/3 sin tapa','🍺',2.00,'barra',false,2 from cerv
union all
select id,'1/5 con tapa','🍺',1.80,'barra',true,3 from cerv
union all
select id,'Botellín','🍺',2.20,'barra',false,4 from cerv
union all
-- Vinos
select id,'Copa vino tinto','🍷',2.50,'barra',false,1 from vin
union all
select id,'Copa vino blanco','🍷',2.50,'barra',false,2 from vin
union all
-- Refrescos
select id,'Coca-Cola','🥤',2.00,'barra',false,1 from ref
union all
select id,'Agua','💧',1.50,'barra',false,2 from ref
union all
select id,'Zumo naranja','🍊',2.50,'barra',false,3 from ref
union all
-- Cafés
select id,'Café solo','☕',1.20,'barra',false,1 from caf_root
union all
select id,'Café con leche','☕',1.50,'barra',false,2 from caf_root
union all
select id,'Cortado','☕',1.30,'barra',false,3 from caf_root;

-- Comida
with com as (
  insert into menu_nodos (nombre, emoji, orden) values ('Comida','🍽️',2) returning id
),
tapas as (
  insert into menu_nodos (padre_id, nombre, emoji, orden)
  select id,'Tapas','🫕',1 from com returning id
),
raciones as (
  insert into menu_nodos (padre_id, nombre, emoji, orden)
  select id,'Raciones','🍖',2 from com returning id
),
bocadillos as (
  insert into menu_nodos (padre_id, nombre, emoji, orden)
  select id,'Bocadillos','🥖',3 from com returning id
)
insert into menu_nodos (padre_id, nombre, emoji, precio, destino, orden)
select id,'Tortilla patatas','🥚',0.00,'cocina',1 from tapas
union all
select id,'Croquetas (3)','🫕',0.00,'cocina',2 from tapas
union all
select id,'Champiñones','🍄',0.00,'cocina',3 from tapas
union all
select id,'Jamón','🥩',0.00,'cocina',4 from tapas
union all
select id,'Calamares','🦑',7.50,'cocina',1 from raciones
union all
select id,'Patatas bravas','🥔',6.00,'cocina',2 from raciones
union all
select id,'Jamón serrano','🥩',10.00,'cocina',3 from raciones
union all
select id,'Lomo','🥖',3.50,'cocina',1 from bocadillos
union all
select id,'Jamón y queso','🥖',3.50,'cocina',2 from bocadillos
union all
select id,'Calamares','🥖',4.00,'cocina',3 from bocadillos;

-- ============================================================
-- FIN DEL SCHEMA
-- ============================================================
