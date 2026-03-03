-- ============================================================
-- COMPANAH — Seed Test Pipeline Data
-- Project: Aloka
--
-- Picks 12 real orders (most recent with care plans) and
-- spreads them across the full status pipeline so the
-- workflow app has something to display.
--
-- Also enriches care plans with memorial selections and
-- creates sample checklist tasks.
--
-- Run in: Supabase SQL Editor
-- Safe to re-run: uses CTEs and conditional updates.
-- ============================================================

-- ── Step 1: Pick 12 recent orders that have care plans ──────

WITH candidates AS (
  SELECT
    o.id AS order_id,
    o.pet_id,
    o.companah_id,
    cp.id AS care_plan_id,
    ROW_NUMBER() OVER (ORDER BY o.created_at DESC) AS rn
  FROM orders.orders o
  JOIN orders.care_plans cp ON cp.order_id = o.id
  WHERE o.pet_id IS NOT NULL
    AND o.owner_contact_id IS NOT NULL
  ORDER BY o.created_at DESC
  LIMIT 12
),

-- ── Step 2: Assign each to a different status ───────────────

status_assignments AS (
  SELECT
    order_id, pet_id, companah_id, care_plan_id, rn,
    CASE rn
      WHEN  1 THEN 'awaiting_pickup'
      WHEN  2 THEN 'awaiting_pickup'
      WHEN  3 THEN 'received'
      WHEN  4 THEN 'triage'
      WHEN  5 THEN 'triage'
      WHEN  6 THEN 'cremation'
      WHEN  7 THEN 'preparing_remains'
      WHEN  8 THEN 'building_memorials'
      WHEN  9 THEN 'building_memorials'
      WHEN 10 THEN 'ready_to_return'
      WHEN 11 THEN 'ready_to_return'
      WHEN 12 THEN 'customer_pickup'
    END AS new_status
  FROM candidates
)

-- ── Step 3: Update the orders ───────────────────────────────

UPDATE orders.orders o
SET
  status = sa.new_status,
  updated_at = now()
FROM status_assignments sa
WHERE o.id = sa.order_id;


-- ── Step 4: Enrich care plans with realistic memorial data ──

WITH candidates AS (
  SELECT
    o.id AS order_id,
    cp.id AS care_plan_id,
    ROW_NUMBER() OVER (ORDER BY o.created_at DESC) AS rn
  FROM orders.orders o
  JOIN orders.care_plans cp ON cp.order_id = o.id
  WHERE o.status IN (
    'awaiting_pickup', 'received', 'triage', 'cremation',
    'preparing_remains', 'building_memorials', 'ready_to_return',
    'customer_pickup'
  )
  ORDER BY o.created_at DESC
  LIMIT 12
)
UPDATE orders.care_plans cp
SET
  vessel = CASE
    WHEN c.rn IN (1, 4, 7, 10) THEN 'Cherry Wood Urn'
    WHEN c.rn IN (2, 5, 8, 11) THEN 'Walnut Keepsake Box'
    WHEN c.rn IN (3, 6, 9, 12) THEN 'Bamboo Scatter Tube'
  END,
  memorial_package = CASE
    WHEN c.rn IN (1, 2, 6, 8) THEN 'Complete Memorial'
    WHEN c.rn IN (3, 5, 9, 11) THEN 'Essentials'
    WHEN c.rn IN (4, 7, 10, 12) THEN 'Paw Prints Only'
  END,
  clay_prints = CASE WHEN c.rn % 3 = 0 THEN 2 ELSE 1 END,
  nose_prints = CASE WHEN c.rn % 4 = 0 THEN 1 ELSE 0 END,
  engraved_prints = CASE WHEN c.rn IN (1, 2, 6, 8) THEN 2 ELSE 0 END,
  shadowbox_prints = CASE WHEN c.rn IN (1, 8) THEN 1 ELSE 0 END,
  engraved_on_urn = c.rn IN (1, 6, 8),
  engraving_text = CASE
    WHEN c.rn IN (1, 6, 8) THEN 'Forever in our hearts'
    ELSE NULL
  END,
  memorial_plan_requested = true,
  memorial_plan_sent = c.rn > 4,
  is_completed = c.rn >= 10,
  owner_selections_locked = c.rn >= 6,
  updated_at = now()
FROM candidates c
WHERE cp.id = c.care_plan_id;


-- ── Step 5: Create workflow tasks (checklists) ──────────────
-- First, ensure we have a template for each checklist type

INSERT INTO workflows.templates (id, name, description)
VALUES
  ('a0000000-0000-0000-0000-000000000001', 'Triage Tasks', 'Intake checklist — actions when a pet is first received'),
  ('a0000000-0000-0000-0000-000000000002', 'Crafting Memorials', 'Production checklist — building memorial items'),
  ('a0000000-0000-0000-0000-000000000003', 'Quality Control', 'Final check before return to owner')
ON CONFLICT (id) DO NOTHING;

-- Create tasks for each of the 12 pipeline orders
-- We'll use a DO block to loop through the orders

DO $$
DECLARE
  rec RECORD;
  task_order INT;
BEGIN
  FOR rec IN
    SELECT o.id AS order_id, o.status, o.pet_id
    FROM orders.orders o
    WHERE o.status IN (
      'awaiting_pickup', 'received', 'triage', 'cremation',
      'preparing_remains', 'building_memorials', 'ready_to_return',
      'customer_pickup'
    )
    ORDER BY o.created_at DESC
    LIMIT 12
  LOOP
    -- Skip if tasks already exist for this order
    IF EXISTS (SELECT 1 FROM workflows.tasks WHERE order_id = rec.order_id LIMIT 1) THEN
      CONTINUE;
    END IF;

    task_order := 1;

    -- ── TRIAGE TASKS ──
    INSERT INTO workflows.tasks (order_id, template_id, title, status, priority)
    VALUES
      (rec.order_id, 'a0000000-0000-0000-0000-000000000001',
       'Verify pet identity & weight',
       CASE WHEN rec.status NOT IN ('awaiting_pickup', 'received') THEN 'done' ELSE 'pending' END,
       'high'),

      (rec.order_id, 'a0000000-0000-0000-0000-000000000001',
       'Make clay paw impressions',
       CASE WHEN rec.status NOT IN ('awaiting_pickup', 'received', 'triage') THEN 'done' ELSE 'pending' END,
       'high'),

      (rec.order_id, 'a0000000-0000-0000-0000-000000000001',
       'Photograph paw prints',
       CASE WHEN rec.status NOT IN ('awaiting_pickup', 'received', 'triage') THEN 'done' ELSE 'pending' END,
       'normal'),

      (rec.order_id, 'a0000000-0000-0000-0000-000000000001',
       'Collect lock of hair',
       CASE WHEN rec.status NOT IN ('awaiting_pickup', 'received', 'triage') THEN 'done' ELSE 'pending' END,
       'normal'),

      (rec.order_id, 'a0000000-0000-0000-0000-000000000001',
       'Scan NFC tag',
       CASE WHEN rec.status NOT IN ('awaiting_pickup', 'received', 'triage') THEN 'done' ELSE 'pending' END,
       'normal');

    -- ── CRAFTING MEMORIALS ──
    INSERT INTO workflows.tasks (order_id, template_id, title, status, priority)
    VALUES
      (rec.order_id, 'a0000000-0000-0000-0000-000000000002',
       'Engrave urn with inscription',
       CASE WHEN rec.status IN ('ready_to_return', 'customer_pickup') THEN 'done' ELSE 'pending' END,
       'high'),

      (rec.order_id, 'a0000000-0000-0000-0000-000000000002',
       'Fire clay paw prints',
       CASE WHEN rec.status IN ('building_memorials', 'ready_to_return', 'customer_pickup') THEN 'done' ELSE 'pending' END,
       'high'),

      (rec.order_id, 'a0000000-0000-0000-0000-000000000002',
       'Engrave wood paw prints',
       CASE WHEN rec.status IN ('ready_to_return', 'customer_pickup') THEN 'done' ELSE 'pending' END,
       'normal'),

      (rec.order_id, 'a0000000-0000-0000-0000-000000000002',
       'Fill urn with remains',
       CASE WHEN rec.status IN ('ready_to_return', 'customer_pickup') THEN 'done' ELSE 'pending' END,
       'high'),

      (rec.order_id, 'a0000000-0000-0000-0000-000000000002',
       'Assemble memorial package',
       CASE WHEN rec.status IN ('ready_to_return', 'customer_pickup') THEN 'done' ELSE 'pending' END,
       'normal');

    -- ── QUALITY CONTROL ──
    INSERT INTO workflows.tasks (order_id, template_id, title, status, priority)
    VALUES
      (rec.order_id, 'a0000000-0000-0000-0000-000000000003',
       'Verify urn engraving accuracy',
       CASE WHEN rec.status IN ('ready_to_return', 'customer_pickup') THEN 'done' ELSE 'pending' END,
       'high'),

      (rec.order_id, 'a0000000-0000-0000-0000-000000000003',
       'Check clay prints — no cracks or defects',
       CASE WHEN rec.status IN ('ready_to_return', 'customer_pickup') THEN 'done' ELSE 'pending' END,
       'high'),

      (rec.order_id, 'a0000000-0000-0000-0000-000000000003',
       'Confirm all memorial items present',
       CASE WHEN rec.status IN ('ready_to_return', 'customer_pickup') THEN 'done' ELSE 'pending' END,
       'normal'),

      (rec.order_id, 'a0000000-0000-0000-0000-000000000003',
       'Package for return — secure and labeled',
       CASE WHEN rec.status = 'customer_pickup' THEN 'done' ELSE 'pending' END,
       'normal');

  END LOOP;
END $$;


-- ── Step 6: Add sample comments ─────────────────────────────

DO $$
DECLARE
  rec RECORD;
  author_id UUID;
BEGIN
  -- Get a team member contact to use as author
  SELECT id INTO author_id FROM core.contacts WHERE role = 'team_member' LIMIT 1;

  -- If no team member exists, use any contact
  IF author_id IS NULL THEN
    SELECT id INTO author_id FROM core.contacts LIMIT 1;
  END IF;

  FOR rec IN
    SELECT o.id AS order_id, o.status, o.pet_id,
           ROW_NUMBER() OVER (ORDER BY o.created_at DESC) AS rn
    FROM orders.orders o
    WHERE o.status IN (
      'awaiting_pickup', 'received', 'triage', 'cremation',
      'preparing_remains', 'building_memorials', 'ready_to_return',
      'customer_pickup'
    )
    ORDER BY o.created_at DESC
    LIMIT 12
  LOOP
    -- Skip if comments already exist
    IF EXISTS (SELECT 1 FROM orders.comments WHERE order_id = rec.order_id LIMIT 1) THEN
      CONTINUE;
    END IF;

    -- General order comment
    INSERT INTO orders.comments (order_id, author_id, body)
    VALUES (rec.order_id, author_id,
      CASE rec.rn
        WHEN 1 THEN 'Pickup scheduled for tomorrow morning. Owner will meet driver at front desk.'
        WHEN 2 THEN 'Vet called — pet is ready for pickup after 3 PM.'
        WHEN 3 THEN 'Pet received in good condition. Owner very emotional, please handle with extra care.'
        WHEN 4 THEN 'Weight confirmed, clay impressions came out great.'
        WHEN 5 THEN 'Owner requested extra set of paw prints for grandmother.'
        WHEN 6 THEN 'In machine now, estimated completion tomorrow AM.'
        WHEN 7 THEN 'Remains ready. Starting memorial prep.'
        WHEN 8 THEN 'Engraving text confirmed with owner: "Forever in our hearts"'
        WHEN 9 THEN 'Clay prints need to re-fire — small crack on left paw.'
        WHEN 10 THEN 'Everything looks perfect. Ready for owner pickup.'
        WHEN 11 THEN 'Owner called — picking up Saturday instead of Friday.'
        WHEN 12 THEN 'Owner notified. Picking up today between 2-4 PM.'
      END
    );

    -- Add a contextual comment on some orders (pinned to care_plan)
    IF rec.rn IN (5, 8, 9) THEN
      INSERT INTO orders.comments (order_id, target_type, target_id, author_id, body)
      SELECT
        rec.order_id, 'care_plan', cp.id, author_id,
        CASE rec.rn
          WHEN 5 THEN 'Adding 1 extra clay print per owner request. Updating care plan.'
          WHEN 8 THEN 'Owner approved engraving proof via email. Proceeding with production.'
          WHEN 9 THEN 'Re-firing clay. Will delay return by 1 day.'
        END
      FROM orders.care_plans cp
      WHERE cp.order_id = rec.order_id
      LIMIT 1;
    END IF;

  END LOOP;
END $$;


-- ── Step 7: Verify ──────────────────────────────────────────

SELECT
  o.status,
  COUNT(*) AS orders,
  COUNT(t.id) AS tasks,
  COUNT(DISTINCT cm.id) AS comments
FROM orders.orders o
LEFT JOIN workflows.tasks t ON t.order_id = o.id
LEFT JOIN orders.comments cm ON cm.order_id = o.id
WHERE o.status IN (
  'awaiting_pickup', 'received', 'triage', 'cremation',
  'preparing_remains', 'building_memorials', 'ready_to_return',
  'customer_pickup'
)
GROUP BY o.status
ORDER BY ARRAY_POSITION(
  ARRAY['awaiting_pickup','received','triage','cremation',
        'preparing_remains','building_memorials','ready_to_return','customer_pickup'],
  o.status
);
