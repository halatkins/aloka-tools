-- ============================================================
-- COMPANAH — Supabase Schema Migration (v5)
-- Project: Aloka (qrnjwdbqzeqtcyzwljvu)
--
-- Run this in the Supabase SQL Editor:
--   Dashboard → SQL Editor → New Query → Paste → Run
--
-- CHANGES FROM v4:
--   • Removed pricing.products and pricing.partner_rates
--     (QBO SKU tables deferred — will add later)
--   • Added care_type to orders.orders (direct/partner/shared)
--   • Renamed client_contact_id → owner_contact_id
--   • Renamed vet_organization_id → partner_organization_id
--   • Added billed_to fields on line_items and invoices
--   • Added care_type + owner_selections_locked to care_plans
--   • Added pocket_pet flag to core.pets
--   • Added partner_code to partners.profiles
--
-- Safe to run on a fresh project — uses IF NOT EXISTS.
-- ============================================================


-- ────────────────────────────────────────────────────────────
-- STEP 0: Helper function for auto-updating timestamps
-- ────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- ────────────────────────────────────────────────────────────
-- STEP 1: Create schemas (namespaces)
-- ────────────────────────────────────────────────────────────

CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS orders;
CREATE SCHEMA IF NOT EXISTS operations;
CREATE SCHEMA IF NOT EXISTS billing;
CREATE SCHEMA IF NOT EXISTS workflows;
CREATE SCHEMA IF NOT EXISTS partners;
CREATE SCHEMA IF NOT EXISTS clients;
CREATE SCHEMA IF NOT EXISTS logistics;

-- Expose schemas to PostgREST (so the API can see them)
ALTER DEFAULT PRIVILEGES IN SCHEMA core GRANT SELECT ON TABLES TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA orders GRANT SELECT ON TABLES TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA operations GRANT SELECT ON TABLES TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA billing GRANT SELECT ON TABLES TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA workflows GRANT SELECT ON TABLES TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA partners GRANT SELECT ON TABLES TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA clients GRANT SELECT ON TABLES TO anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA logistics GRANT SELECT ON TABLES TO anon, authenticated;

-- Grant schema usage
GRANT USAGE ON SCHEMA core TO anon, authenticated, service_role;
GRANT USAGE ON SCHEMA orders TO anon, authenticated, service_role;
GRANT USAGE ON SCHEMA operations TO anon, authenticated, service_role;
GRANT USAGE ON SCHEMA billing TO anon, authenticated, service_role;
GRANT USAGE ON SCHEMA workflows TO anon, authenticated, service_role;
GRANT USAGE ON SCHEMA partners TO anon, authenticated, service_role;
GRANT USAGE ON SCHEMA clients TO anon, authenticated, service_role;
GRANT USAGE ON SCHEMA logistics TO anon, authenticated, service_role;

-- Grant full table access to service_role
ALTER DEFAULT PRIVILEGES IN SCHEMA core GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA orders GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA operations GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA billing GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA workflows GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA partners GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA clients GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA logistics GRANT ALL ON TABLES TO service_role;

-- Reload PostgREST config
NOTIFY pgrst, 'reload config';


-- ════════════════════════════════════════════════════════════
-- STEP 2: CORE SCHEMA — Shared entities
-- ════════════════════════════════════════════════════════════

-- ── core.organizations ──────────────────────────────────────
CREATE TABLE IF NOT EXISTS core.organizations (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text NOT NULL,
  type          text CHECK (type IN ('vet_partner', 'companah', 'facility')),
  abbreviation  text,
  phone         text,
  email         text,
  address_line_1 text,
  address_line_2 text,
  city          text,
  state         text,
  zip           text,
  region        text,
  notes         text,
  logo_url      text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER organizations_updated_at
  BEFORE UPDATE ON core.organizations
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

COMMENT ON TABLE core.organizations IS 'Vet clinics, Companah locations, cremation facilities';

-- ── core.contacts ───────────────────────────────────────────
CREATE TABLE IF NOT EXISTS core.contacts (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id uuid REFERENCES core.organizations(id) ON DELETE SET NULL,
  first_name      text,
  last_name       text,
  email           text,
  phone           text,
  address_line_1  text,
  address_line_2  text,
  city            text,
  state           text,
  zip             text,
  role            text CHECK (role IN ('owner', 'vet_staff', 'admin', 'team_member')),
  auth_user_id    uuid,  -- links to auth.users (managed by Supabase Auth)
  region          text,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_contacts_organization ON core.contacts(organization_id);
CREATE INDEX idx_contacts_email ON core.contacts(email);
CREATE INDEX idx_contacts_role ON core.contacts(role);
CREATE INDEX idx_contacts_auth_user ON core.contacts(auth_user_id);

CREATE TRIGGER contacts_updated_at
  BEFORE UPDATE ON core.contacts
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

COMMENT ON TABLE core.contacts IS 'All people — pet owners, vet staff, Companah team, app users';

-- ── core.pets ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS core.pets (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id            uuid REFERENCES core.contacts(id) ON DELETE SET NULL,
  name                text,
  species             text CHECK (species IN ('dog', 'cat', 'bird', 'reptile', 'rabbit', 'hamster', 'guinea_pig', 'other')),
  breed               text,
  color               text,
  gender              text CHECK (gender IN ('male', 'female')),
  weight_lbs          numeric,
  is_pocket_pet       boolean DEFAULT false,
  date_of_passing     date,
  special_instructions text,
  images              jsonb DEFAULT '[]'::jsonb,
  pet_pic             jsonb,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_pets_owner ON core.pets(owner_id);
CREATE INDEX idx_pets_pocket ON core.pets(is_pocket_pet);

CREATE TRIGGER pets_updated_at
  BEFORE UPDATE ON core.pets
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

COMMENT ON TABLE core.pets IS 'The animals — linked to their owner contact. is_pocket_pet distinguishes pocket pets (rabbits, hamsters, etc.)';


-- ════════════════════════════════════════════════════════════
-- STEP 3: ORDERS SCHEMA — Cremation order lifecycle
-- ════════════════════════════════════════════════════════════
-- NOTE: pricing schema omitted for now (QBO SKU cleanup in progress)

-- ── orders.orders ───────────────────────────────────────────
CREATE TABLE IF NOT EXISTS orders.orders (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  companah_id               text UNIQUE,
  nfc_id                    text,
  pet_id                    uuid REFERENCES core.pets(id) ON DELETE SET NULL,

  -- Care model: who initiated and who pays
  care_type                 text CHECK (care_type IN ('direct', 'partner', 'shared')) DEFAULT 'partner',

  -- Owner (pet parent) — always tracked regardless of care type
  owner_contact_id          uuid REFERENCES core.contacts(id) ON DELETE SET NULL,

  -- Partner vet — NULL for direct care
  partner_organization_id   uuid REFERENCES core.organizations(id) ON DELETE SET NULL,
  attending_doctor          text,

  -- Order status & service
  status                    text CHECK (status IN (
                              'preplanning', 'on_hold', 'awaiting_pickup', 'received',
                              'triage', 'cremation', 'complete', 'delivered'
                            )),
  service_type              text CHECK (service_type IN (
                              'private', 'communal', 'semi_private', 'biodegradable', 'memorials_only'
                            )),

  -- Locations
  intake_location           text,
  companah_location         text,
  current_location          text,

  -- Dates
  date_received             date,
  cremation_date            date,
  date_returned             date,
  planned_return            date,

  -- Delivery
  delivery_method           text CHECK (delivery_method IN (
                              'primary_care', 'other_vet', 'direct_to_owner', 'owner_pickup'
                            )),
  pickup_location           text,
  return_location           text,

  -- Flags & notes
  is_vet_referral           boolean DEFAULT false,
  notes                     text,
  intake_email              text,
  referring_vet_info        text,
  special_case              text,
  is_stalled                boolean DEFAULT false,
  intake_pdf_url            text,
  care_plan_url             text,

  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_orders_pet ON orders.orders(pet_id);
CREATE INDEX idx_orders_owner ON orders.orders(owner_contact_id);
CREATE INDEX idx_orders_partner_org ON orders.orders(partner_organization_id);
CREATE INDEX idx_orders_status ON orders.orders(status);
CREATE INDEX idx_orders_care_type ON orders.orders(care_type);
CREATE INDEX idx_orders_companah_id ON orders.orders(companah_id);
CREATE INDEX idx_orders_date_received ON orders.orders(date_received);

CREATE TRIGGER orders_updated_at
  BEFORE UPDATE ON orders.orders
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

COMMENT ON TABLE orders.orders IS 'Cremation orders from intake to delivery. care_type: direct (B2C), partner (B2B), shared (hybrid)';

-- ── orders.line_items ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS orders.line_items (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id        uuid NOT NULL REFERENCES orders.orders(id) ON DELETE CASCADE,
  description     text,
  sku             text,       -- references future pricing.products when ready
  quantity        numeric DEFAULT 1,
  unit_price      numeric,
  total           numeric,

  -- For shared care: who gets billed for this line?
  billed_to_type  text CHECK (billed_to_type IN ('partner', 'owner')),
  billed_to_id    uuid,       -- contact_id (owner) or organization_id (partner)

  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_line_items_order ON orders.line_items(order_id);
CREATE INDEX idx_line_items_billed ON orders.line_items(billed_to_type);

COMMENT ON TABLE orders.line_items IS 'Products/services on an order. billed_to splits charges for shared care';

-- ── orders.care_plans ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS orders.care_plans (
  id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id                  uuid NOT NULL REFERENCES orders.orders(id) ON DELETE CASCADE,

  -- Which care model does this plan serve?
  care_type                 text CHECK (care_type IN ('direct', 'partner', 'shared')),

  -- Completion tracking
  is_completed              boolean DEFAULT false,
  owner_selections_locked   boolean DEFAULT false,
  completed_pdf_url         text,

  -- Vessel & memorial selections
  vessel                    text,
  memorial_package          text,
  clay_prints               integer DEFAULT 0,
  nose_prints               integer DEFAULT 0,
  engraved_prints           integer DEFAULT 0,
  shadowbox_prints          integer DEFAULT 0,
  engraved_on_urn           boolean DEFAULT false,
  engraving_text            text,
  memorial_plan_requested   boolean DEFAULT false,
  memorial_plan_sent        boolean DEFAULT false,
  clay_prints_completed     boolean DEFAULT false,
  memorial_items_list       text,
  retained_items            text,

  created_at                timestamptz NOT NULL DEFAULT now(),
  updated_at                timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_care_plans_order ON orders.care_plans(order_id);
CREATE INDEX idx_care_plans_care_type ON orders.care_plans(care_type);

CREATE TRIGGER care_plans_updated_at
  BEFORE UPDATE ON orders.care_plans
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

COMMENT ON TABLE orders.care_plans IS 'Care plan details — vessel, prints, engraving. owner_selections_locked freezes the plan for shared care billing';

-- ── orders.memorials ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS orders.memorials (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id    uuid NOT NULL REFERENCES orders.orders(id) ON DELETE CASCADE,
  pet_id      uuid REFERENCES core.pets(id) ON DELETE SET NULL,
  tribute_text text,
  photo_urls  jsonb DEFAULT '[]'::jsonb,
  is_public   boolean DEFAULT false,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_memorials_order ON orders.memorials(order_id);
CREATE INDEX idx_memorials_pet ON orders.memorials(pet_id);

CREATE TRIGGER memorials_updated_at
  BEFORE UPDATE ON orders.memorials
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

COMMENT ON TABLE orders.memorials IS 'Tribute pages with photos and text, optionally public';


-- ════════════════════════════════════════════════════════════
-- STEP 4: OPERATIONS SCHEMA — Cremation processing
-- ════════════════════════════════════════════════════════════

-- ── operations.machines ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS operations.machines (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name          text NOT NULL,
  machine_type  text,
  facility      text,
  is_active     boolean DEFAULT true,
  created_at    timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE operations.machines IS 'Cremation equipment registry — Donatello, Michelangelo, Leonardo';

-- ── operations.runs ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS operations.runs (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  machine_id          uuid NOT NULL REFERENCES operations.machines(id) ON DELETE CASCADE,
  process_number      integer,
  run_date            date,
  koh_weight_lbs      numeric,
  naoh_weight_lbs     numeric,
  bulk_weight_lbs     numeric,
  slack_confirmation  text CHECK (slack_confirmation IN ('confirmed', 'not_confirmed')),
  slack_user          text,
  attachments         jsonb DEFAULT '[]'::jsonb,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_runs_machine ON operations.runs(machine_id);
CREATE INDEX idx_runs_date ON operations.runs(run_date);

CREATE TRIGGER runs_updated_at
  BEFORE UPDATE ON operations.runs
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

COMMENT ON TABLE operations.runs IS 'A single processing run — date, chemicals, bulk weight, Slack confirmation';

-- ── operations.run_pets ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS operations.run_pets (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  run_id          uuid NOT NULL REFERENCES operations.runs(id) ON DELETE CASCADE,
  order_id        uuid NOT NULL REFERENCES orders.orders(id) ON DELETE CASCADE,
  pet_weight_lbs  numeric,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_run_pets_run ON operations.run_pets(run_id);
CREATE INDEX idx_run_pets_order ON operations.run_pets(order_id);

COMMENT ON TABLE operations.run_pets IS 'Junction: which orders (pets) were in which run';


-- ════════════════════════════════════════════════════════════
-- STEP 5: BILLING SCHEMA — Invoicing
-- ════════════════════════════════════════════════════════════

-- ── billing.invoices ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS billing.invoices (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id                uuid REFERENCES orders.orders(id) ON DELETE SET NULL,

  -- Who is this invoice addressed to?
  billed_to_type          text CHECK (billed_to_type IN ('partner', 'owner')),
  billed_to_contact_id    uuid REFERENCES core.contacts(id) ON DELETE SET NULL,
  billed_to_org_id        uuid REFERENCES core.organizations(id) ON DELETE SET NULL,

  -- QBO sync (kept for future integration)
  qbo_invoice_id          text,
  qbo_invoice_number      text,
  qbo_customer_id         text,
  qbo_customer_name       text,
  qbo_customer_email      text,

  -- Invoice details
  invoice_date            date,
  due_date                date,
  terms                   text CHECK (terms IN ('on_receipt', 'net_30', 'net_60')),
  invoice_amount          numeric,
  balance_due             numeric,
  status                  text CHECK (status IN ('draft', 'sent', 'paid', 'overdue', 'void')),
  most_recent_payment     date,
  memo                    text,

  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_invoices_order ON billing.invoices(order_id);
CREATE INDEX idx_invoices_billed_contact ON billing.invoices(billed_to_contact_id);
CREATE INDEX idx_invoices_billed_org ON billing.invoices(billed_to_org_id);
CREATE INDEX idx_invoices_billed_type ON billing.invoices(billed_to_type);
CREATE INDEX idx_invoices_status ON billing.invoices(status);
CREATE INDEX idx_invoices_qbo_id ON billing.invoices(qbo_invoice_id);

CREATE TRIGGER invoices_updated_at
  BEFORE UPDATE ON billing.invoices
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

COMMENT ON TABLE billing.invoices IS 'Invoice headers. billed_to_type enables split billing for shared care (one order → two invoices)';

-- ── billing.invoice_line_items ──────────────────────────────
CREATE TABLE IF NOT EXISTS billing.invoice_line_items (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  invoice_id        uuid NOT NULL REFERENCES billing.invoices(id) ON DELETE CASCADE,
  description       text,
  sku               text,       -- references future pricing.products when ready
  quantity          numeric DEFAULT 1,
  rate              numeric,
  amount            numeric,
  service_date      date,
  is_taxable        boolean DEFAULT false,
  tax_rate          text,
  shipping_address  text,
  created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_invoice_lines_invoice ON billing.invoice_line_items(invoice_id);

COMMENT ON TABLE billing.invoice_line_items IS 'Line items on an invoice — description, qty, rate, tax';


-- ════════════════════════════════════════════════════════════
-- STEP 6: WORKFLOWS SCHEMA — Task management
-- ════════════════════════════════════════════════════════════

-- ── workflows.templates ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS workflows.templates (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL,
  description text,
  steps       jsonb DEFAULT '[]'::jsonb,
  is_active   boolean DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE workflows.templates IS 'Reusable workflow blueprints (e.g. Standard Private Cremation)';

-- ── workflows.tasks ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS workflows.tasks (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id      uuid REFERENCES orders.orders(id) ON DELETE SET NULL,
  template_id   uuid REFERENCES workflows.templates(id) ON DELETE SET NULL,
  title         text NOT NULL,
  description   text,
  status        text CHECK (status IN ('pending', 'in_progress', 'blocked', 'done')) DEFAULT 'pending',
  priority      text CHECK (priority IN ('low', 'normal', 'high', 'urgent')) DEFAULT 'normal',
  assigned_to   uuid REFERENCES core.contacts(id) ON DELETE SET NULL,
  due_date      date,
  completed_at  timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_tasks_order ON workflows.tasks(order_id);
CREATE INDEX idx_tasks_assigned ON workflows.tasks(assigned_to);
CREATE INDEX idx_tasks_status ON workflows.tasks(status);

CREATE TRIGGER tasks_updated_at
  BEFORE UPDATE ON workflows.tasks
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

COMMENT ON TABLE workflows.tasks IS 'Individual work items, optionally linked to an order';

-- ── workflows.comments ──────────────────────────────────────
CREATE TABLE IF NOT EXISTS workflows.comments (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id     uuid NOT NULL REFERENCES workflows.tasks(id) ON DELETE CASCADE,
  author_id   uuid REFERENCES core.contacts(id) ON DELETE SET NULL,
  body        text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_comments_task ON workflows.comments(task_id);

COMMENT ON TABLE workflows.comments IS 'Discussion on tasks';


-- ════════════════════════════════════════════════════════════
-- STEP 7: PARTNERS SCHEMA — Vet partner portal
-- ════════════════════════════════════════════════════════════

-- ── partners.profiles ───────────────────────────────────────
CREATE TABLE IF NOT EXISTS partners.profiles (
  id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id             uuid NOT NULL REFERENCES core.organizations(id) ON DELETE CASCADE,
  partner_code                text UNIQUE,  -- e.g. 'LOVT', 'DRPL' — used in SKU prefixes
  tier                        text CHECK (tier IN ('standard', 'preferred', 'premium')),
  billing_method              text CHECK (billing_method IN ('per_order', 'monthly_invoice')),
  wholesale_rate_individual   numeric,
  wholesale_rate_communal     numeric,
  overweight_surcharge        numeric DEFAULT 25.00,  -- flat surcharge for pets > 125 lbs
  qbo_customer_id             text,
  qbo_current_invoice_id      text,
  magic_link_url              text,
  rating                      integer CHECK (rating >= 1 AND rating <= 5),
  user_type                   text CHECK (user_type IN ('vet', 'owner')),
  portal_preferences          jsonb DEFAULT '{}'::jsonb,
  created_at                  timestamptz NOT NULL DEFAULT now(),
  updated_at                  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_partner_profiles_org ON partners.profiles(organization_id);
CREATE INDEX idx_partner_profiles_code ON partners.profiles(partner_code);

CREATE TRIGGER partner_profiles_updated_at
  BEFORE UPDATE ON partners.profiles
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

COMMENT ON TABLE partners.profiles IS 'Partner-specific config — tier, billing, wholesale rates, partner code for SKU prefix';

-- ── partners.referrals ──────────────────────────────────────
CREATE TABLE IF NOT EXISTS partners.referrals (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  partner_profile_id    uuid NOT NULL REFERENCES partners.profiles(id) ON DELETE CASCADE,
  order_id              uuid NOT NULL REFERENCES orders.orders(id) ON DELETE CASCADE,
  referring_contact_id  uuid REFERENCES core.contacts(id) ON DELETE SET NULL,
  referred_date         date,
  notes                 text,
  created_at            timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_referrals_partner ON partners.referrals(partner_profile_id);
CREATE INDEX idx_referrals_order ON partners.referrals(order_id);

COMMENT ON TABLE partners.referrals IS 'Which orders came through which partner';


-- ════════════════════════════════════════════════════════════
-- STEP 8: CLIENTS SCHEMA — Client portal & reviews
-- ════════════════════════════════════════════════════════════

-- ── clients.portal_access ───────────────────────────────────
CREATE TABLE IF NOT EXISTS clients.portal_access (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contact_id       uuid NOT NULL REFERENCES core.contacts(id) ON DELETE CASCADE,
  order_id         uuid NOT NULL REFERENCES orders.orders(id) ON DELETE CASCADE,
  access_token     text,
  temp_password    text,
  expires_at       timestamptz,
  last_accessed_at timestamptz,
  created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_portal_contact ON clients.portal_access(contact_id);
CREATE INDEX idx_portal_order ON clients.portal_access(order_id);

COMMENT ON TABLE clients.portal_access IS 'Token-based or temp-password access for order status';

-- ── clients.reviews ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS clients.reviews (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  contact_id            uuid NOT NULL REFERENCES core.contacts(id) ON DELETE CASCADE,
  order_id              uuid NOT NULL REFERENCES orders.orders(id) ON DELETE CASCADE,
  review_status         text CHECK (review_status IN (
                          'needs_request', 'request_sent', 'review_done', 'possible_negative'
                        )),
  review_request_sent   boolean DEFAULT false,
  review_notes          text,
  review_sent_date      date,
  created_at            timestamptz NOT NULL DEFAULT now(),
  updated_at            timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_reviews_contact ON clients.reviews(contact_id);
CREATE INDEX idx_reviews_order ON clients.reviews(order_id);

CREATE TRIGGER reviews_updated_at
  BEFORE UPDATE ON clients.reviews
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

COMMENT ON TABLE clients.reviews IS 'Review request lifecycle tracking';


-- ════════════════════════════════════════════════════════════
-- STEP 9: LOGISTICS SCHEMA — Delivery & pickup tracking
-- ════════════════════════════════════════════════════════════

-- ── logistics.locations ─────────────────────────────────────
CREATE TABLE IF NOT EXISTS logistics.locations (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name            text NOT NULL,
  organization_id uuid REFERENCES core.organizations(id) ON DELETE SET NULL,
  location_type   text CHECK (location_type IN ('vet_clinic', 'client_home', 'companah_facility', 'other')),
  address_line_1  text,
  address_line_2  text,
  city            text,
  state           text,
  zip             text,
  region          text,
  contact_name    text,
  contact_phone   text,
  hours           text,
  access_notes    text,
  is_active       boolean DEFAULT true,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_locations_org ON logistics.locations(organization_id);
CREATE INDEX idx_locations_type ON logistics.locations(location_type);
CREATE INDEX idx_locations_active ON logistics.locations(is_active);

CREATE TRIGGER locations_updated_at
  BEFORE UPDATE ON logistics.locations
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

COMMENT ON TABLE logistics.locations IS 'Directory of places Companah visits — vet clinics, homes, facilities';

-- ── logistics.routes ────────────────────────────────────────
CREATE TABLE IF NOT EXISTS logistics.routes (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  route_date    date,
  route_name    text,
  driver_id     uuid REFERENCES core.contacts(id) ON DELETE SET NULL,
  vehicle       text,
  status        text CHECK (status IN ('planned', 'in_progress', 'completed', 'cancelled')) DEFAULT 'planned',
  region        text,
  started_at    timestamptz,
  completed_at  timestamptz,
  notes         text,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_routes_driver ON logistics.routes(driver_id);
CREATE INDEX idx_routes_date ON logistics.routes(route_date);
CREATE INDEX idx_routes_status ON logistics.routes(status);

CREATE TRIGGER routes_updated_at
  BEFORE UPDATE ON logistics.routes
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

COMMENT ON TABLE logistics.routes IS 'A delivery/pickup trip — driver, date, vehicle, region';

-- ── logistics.stops ─────────────────────────────────────────
CREATE TABLE IF NOT EXISTS logistics.stops (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  route_id          uuid NOT NULL REFERENCES logistics.routes(id) ON DELETE CASCADE,
  location_id       uuid REFERENCES logistics.locations(id) ON DELETE SET NULL,
  stop_order        integer,
  stop_type         text CHECK (stop_type IN ('pickup', 'delivery', 'both')),
  override_address  text,
  arrived_at        timestamptz,
  departed_at       timestamptz,
  status            text CHECK (status IN ('pending', 'arrived', 'completed', 'skipped')) DEFAULT 'pending',
  notes             text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_stops_route ON logistics.stops(route_id);
CREATE INDEX idx_stops_location ON logistics.stops(location_id);

CREATE TRIGGER stops_updated_at
  BEFORE UPDATE ON logistics.stops
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

COMMENT ON TABLE logistics.stops IS 'Each location visited on a route, in sequence';

-- ── logistics.stop_items ────────────────────────────────────
CREATE TABLE IF NOT EXISTS logistics.stop_items (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  stop_id           uuid NOT NULL REFERENCES logistics.stops(id) ON DELETE CASCADE,
  order_id          uuid NOT NULL REFERENCES orders.orders(id) ON DELETE CASCADE,
  action            text CHECK (action IN ('pickup', 'delivery')),
  item_description  text,
  status            text CHECK (status IN ('pending', 'completed')) DEFAULT 'pending',
  notes             text,
  created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX idx_stop_items_stop ON logistics.stop_items(stop_id);
CREATE INDEX idx_stop_items_order ON logistics.stop_items(order_id);

COMMENT ON TABLE logistics.stop_items IS 'What happened at each stop — which pets picked up or delivered';


-- ════════════════════════════════════════════════════════════
-- STEP 10: Seed data for operations machines
-- ════════════════════════════════════════════════════════════

INSERT INTO operations.machines (name, machine_type, facility, is_active)
VALUES
  ('Donatello', 'alkaline_hydrolysis', 'Sanford', true),
  ('Michelangelo', 'alkaline_hydrolysis', 'Sanford', true),
  ('Leonardo', 'alkaline_hydrolysis', 'Sanford', true)
ON CONFLICT DO NOTHING;


-- ════════════════════════════════════════════════════════════
-- DONE! Summary of what was created:
-- ════════════════════════════════════════════════════════════
--
-- 8 schemas (pricing deferred):
--   core, orders, operations, billing,
--   workflows, partners, clients, logistics
--
-- 22 tables:
--   core:       organizations, contacts, pets
--   orders:     orders, line_items, care_plans, memorials
--   operations: machines, runs, run_pets
--   billing:    invoices, invoice_line_items
--   workflows:  templates, tasks, comments
--   partners:   profiles, referrals
--   clients:    portal_access, reviews
--   logistics:  locations, routes, stops, stop_items
--
-- v5 changes from v4:
--   ✓ Removed pricing schema (QBO SKU tables deferred)
--   ✓ Added care_type ('direct'/'partner'/'shared') to orders
--   ✓ Renamed client_contact_id → owner_contact_id
--   ✓ Renamed vet_organization_id → partner_organization_id
--   ✓ Added billed_to_type + billed_to_id on line_items
--   ✓ Added billed_to_type/contact/org on invoices (split billing)
--   ✓ Added care_type + owner_selections_locked on care_plans
--   ✓ Added is_pocket_pet flag to pets
--   ✓ Added partner_code (UNIQUE) to partners.profiles
--   ✓ Added overweight_surcharge to partners.profiles
--   ✓ Added sku text field to line_items + invoice_line_items
--   ✓ Expanded species CHECK to include rabbit, hamster, guinea_pig
--
-- Seed data:
--   ✓ 3 cremation machines (Donatello, Michelangelo, Leonardo)
--
-- Next steps:
--   1. Paste this SQL into Supabase SQL Editor and run
--   2. Enable RLS on each table via the Supabase dashboard
--   3. Expose schemas in API settings (Settings → API → Schema)
--   4. Run the Airtable migration to populate data
-- ════════════════════════════════════════════════════════════
