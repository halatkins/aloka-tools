// ============================================================
// COMPANAH — Fillout Webhook Edge Function
// Project: Aloka
//
// Handles three form types:
//   1. Direct Care intake  → ?type=direct
//   2. Partner intake       → ?type=partner&code=VETCODE
//   3. Care Plan update     → ?type=careplan&pet=AIRTABLE_ID
//
// Fillout sends a JSON payload on form submission.
// This function maps fields → Supabase tables.
//
// Deploy:
//   supabase functions deploy intake-webhook --no-verify-jwt
// ============================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  db: { schema: "public" },
});

// ── Helpers ──────────────────────────────────────────────────

/** Extract a Fillout field value by field name (case-insensitive) */
function getField(fields: any[], name: string): any {
  const f = fields.find(
    (f: any) => f.name?.toLowerCase() === name.toLowerCase()
  );
  return f?.value ?? null;
}

/** Map species string to our CHECK constraint values */
function mapSpecies(raw: string | null): string | null {
  if (!raw) return null;
  const lower = raw.toLowerCase().trim();
  const map: Record<string, string> = {
    dog: "dog",
    cat: "cat",
    bird: "bird",
    reptile: "reptile",
    rabbit: "rabbit",
    hamster: "hamster",
    guinea_pig: "guinea_pig",
    "guinea pig": "guinea_pig",
    other: "other",
  };
  return map[lower] || "other";
}

/** Map gender string */
function mapGender(raw: string | null): string | null {
  if (!raw) return null;
  const lower = raw.toLowerCase().trim();
  if (lower.startsWith("m")) return "male";
  if (lower.startsWith("f")) return "female";
  return null;
}

/** Build a JSON response */
function jsonResponse(data: any, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

// ── Direct Care & Partner Intake ─────────────────────────────
// Creates: contact (owner) + pet + order
// Partner intake also links to the vet org via partner_code

async function handleIntake(
  fields: any[],
  careType: "direct" | "partner",
  partnerCode: string | null
) {
  // ── 1. Look up partner org (if partner intake) ──
  let partnerOrgId: string | null = null;

  if (careType === "partner" && partnerCode) {
    const { data: profile } = await supabase
      .schema("partners")
      .from("profiles")
      .select("organization_id")
      .eq("partner_code", partnerCode.toUpperCase())
      .single();

    if (!profile) {
      return jsonResponse(
        { error: `Unknown partner code: ${partnerCode}` },
        400
      );
    }
    partnerOrgId = profile.organization_id;
  }

  // ── 2. Create or find the owner contact ──
  const ownerEmail = getField(fields, "Owner Email") || getField(fields, "Email");
  const ownerFirst = getField(fields, "Owner First Name") || getField(fields, "First Name");
  const ownerLast = getField(fields, "Owner Last Name") || getField(fields, "Last Name");
  const ownerPhone = getField(fields, "Owner Phone") || getField(fields, "Phone");
  const ownerAddress = getField(fields, "Address");
  const ownerCity = getField(fields, "City");
  const ownerState = getField(fields, "State");
  const ownerZip = getField(fields, "Zip") || getField(fields, "Zip Code");

  let ownerId: string | null = null;

  // Try to find existing contact by email first
  if (ownerEmail) {
    const { data: existing } = await supabase
      .schema("core")
      .from("contacts")
      .select("id")
      .eq("email", ownerEmail)
      .eq("role", "owner")
      .maybeSingle();

    if (existing) {
      ownerId = existing.id;
      // Update with any new info
      await supabase
        .schema("core")
        .from("contacts")
        .update({
          first_name: ownerFirst || undefined,
          last_name: ownerLast || undefined,
          phone: ownerPhone || undefined,
          address_line_1: ownerAddress || undefined,
          city: ownerCity || undefined,
          state: ownerState || undefined,
          zip: ownerZip || undefined,
        })
        .eq("id", ownerId);
    }
  }

  // Create new contact if not found
  if (!ownerId) {
    const { data: newContact, error: contactError } = await supabase
      .schema("core")
      .from("contacts")
      .insert({
        first_name: ownerFirst,
        last_name: ownerLast,
        email: ownerEmail,
        phone: ownerPhone,
        address_line_1: ownerAddress,
        city: ownerCity,
        state: ownerState,
        zip: ownerZip,
        role: "owner",
      })
      .select("id")
      .single();

    if (contactError) {
      return jsonResponse({ error: "Failed to create contact", details: contactError }, 500);
    }
    ownerId = newContact.id;
  }

  // ── 3. Create the pet ──
  const petName = getField(fields, "Pet Name") || getField(fields, "Pet's Name");
  const species = mapSpecies(getField(fields, "Species") || getField(fields, "Type of Pet"));
  const breed = getField(fields, "Breed");
  const color = getField(fields, "Color");
  const gender = mapGender(getField(fields, "Gender") || getField(fields, "Sex"));
  const weightRaw = getField(fields, "Weight") || getField(fields, "Weight (lbs)");
  const weight = weightRaw ? parseFloat(weightRaw) : null;
  const dateOfPassing = getField(fields, "Date of Passing");
  const specialInstructions =
    getField(fields, "Special Instructions") || getField(fields, "Notes");

  const { data: pet, error: petError } = await supabase
    .schema("core")
    .from("pets")
    .insert({
      owner_id: ownerId,
      name: petName,
      owner_last_name: ownerLast,
      species,
      breed,
      color,
      gender,
      weight_lbs: weight,
      is_pocket_pet: ["rabbit", "hamster", "guinea_pig"].includes(species || ""),
      date_of_passing: dateOfPassing || null,
      special_instructions: specialInstructions,
    })
    .select("id")
    .single();

  if (petError) {
    return jsonResponse({ error: "Failed to create pet", details: petError }, 500);
  }

  // ── 4. Create the order ──
  const attendingDoctor = getField(fields, "Attending Doctor") || getField(fields, "Veterinarian");
  const serviceType = getField(fields, "Service Type");
  const deliveryMethod = getField(fields, "Delivery Method") || getField(fields, "Return Method");

  // Map service type to CHECK constraint
  const serviceMap: Record<string, string> = {
    private: "private",
    communal: "communal",
    "semi-private": "semi_private",
    "semi private": "semi_private",
    biodegradable: "biodegradable",
    "memorials only": "memorials_only",
  };
  const mappedService = serviceType
    ? serviceMap[serviceType.toLowerCase().trim()] || null
    : null;

  // Map delivery method to CHECK constraint
  const deliveryMap: Record<string, string> = {
    "primary care": "primary_care",
    "primary vet": "primary_care",
    "other vet": "other_vet",
    "direct to owner": "direct_to_owner",
    "owner pickup": "owner_pickup",
    pickup: "owner_pickup",
  };
  const mappedDelivery = deliveryMethod
    ? deliveryMap[deliveryMethod.toLowerCase().trim()] || null
    : null;

  const { data: order, error: orderError } = await supabase
    .schema("orders")
    .from("orders")
    .insert({
      pet_id: pet.id,
      care_type: careType,
      owner_contact_id: ownerId,
      partner_organization_id: partnerOrgId,
      attending_doctor: attendingDoctor,
      status: "awaiting_pickup",
      service_type: mappedService,
      delivery_method: mappedDelivery,
      is_vet_referral: careType === "partner",
      notes: getField(fields, "Additional Notes") || getField(fields, "Order Notes"),
      intake_email: ownerEmail,
    })
    .select("id")
    .single();

  if (orderError) {
    return jsonResponse({ error: "Failed to create order", details: orderError }, 500);
  }

  // ── 5. Create empty care plan shell ──
  const { error: cpError } = await supabase
    .schema("orders")
    .from("care_plans")
    .insert({
      order_id: order.id,
      care_type: careType,
      is_completed: false,
      owner_selections_locked: false,
    });

  if (cpError) {
    console.error("Care plan creation failed (non-fatal):", cpError);
  }

  return jsonResponse({
    success: true,
    type: careType,
    contact_id: ownerId,
    pet_id: pet.id,
    order_id: order.id,
    pet_name: petName,
    owner_name: [ownerFirst, ownerLast].filter(Boolean).join(" "),
  });
}

// ── Care Plan Update ─────────────────────────────────────────
// Looks up existing pet by airtable_record_id (transitional)
// or Supabase pet UUID, then updates the care plan.

async function handleCarePlan(fields: any[], petIdentifier: string) {
  // Try to find the pet — first by airtable_record_id, then by UUID
  let petId: string | null = null;
  let orderId: string | null = null;

  // Try airtable_record_id first (transitional)
  const { data: petByAirtable } = await supabase
    .schema("core")
    .from("pets")
    .select("id")
    .eq("airtable_record_id", petIdentifier)
    .maybeSingle();

  if (petByAirtable) {
    petId = petByAirtable.id;
  } else {
    // Try as direct Supabase UUID
    const { data: petByUuid } = await supabase
      .schema("core")
      .from("pets")
      .select("id")
      .eq("id", petIdentifier)
      .maybeSingle();

    if (petByUuid) {
      petId = petByUuid.id;
    }
  }

  if (!petId) {
    return jsonResponse({ error: `Pet not found: ${petIdentifier}` }, 404);
  }

  // Find the most recent open order for this pet
  const { data: order } = await supabase
    .schema("orders")
    .from("orders")
    .select("id")
    .eq("pet_id", petId)
    .neq("status", "closed")
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (!order) {
    return jsonResponse({ error: `No open order found for pet: ${petIdentifier}` }, 404);
  }
  orderId = order.id;

  // Find existing care plan or create one
  const { data: existingCP } = await supabase
    .schema("orders")
    .from("care_plans")
    .select("id")
    .eq("order_id", orderId)
    .maybeSingle();

  // Build the care plan update payload from form fields
  const cpData: Record<string, any> = {};

  const vessel = getField(fields, "Vessel") || getField(fields, "Urn Selection");
  if (vessel) cpData.vessel = vessel;

  const memorialPackage = getField(fields, "Memorial Package");
  if (memorialPackage) cpData.memorial_package = memorialPackage;

  const clayPrints = getField(fields, "Clay Prints") || getField(fields, "Clay Paw Prints");
  if (clayPrints != null) cpData.clay_prints = parseInt(clayPrints) || 0;

  const nosePrints = getField(fields, "Nose Prints");
  if (nosePrints != null) cpData.nose_prints = parseInt(nosePrints) || 0;

  const engravedPrints = getField(fields, "Engraved Prints") || getField(fields, "Engraved Paw Prints");
  if (engravedPrints != null) cpData.engraved_prints = parseInt(engravedPrints) || 0;

  const shadowboxPrints = getField(fields, "Shadowbox Prints") || getField(fields, "Shadowbox Paw Print");
  if (shadowboxPrints != null) cpData.shadowbox_prints = parseInt(shadowboxPrints) || 0;

  const engravedOnUrn = getField(fields, "Engraved on Urn") || getField(fields, "Engraved Print on Urn");
  if (engravedOnUrn != null) cpData.engraved_on_urn = Boolean(engravedOnUrn);

  const engravingText = getField(fields, "Engraving Text") || getField(fields, "Text for Engraving");
  if (engravingText) cpData.engraving_text = engravingText;

  const memorialPlan = getField(fields, "Memorial Plan") || getField(fields, "Memorial Plan Requested");
  if (memorialPlan != null) cpData.memorial_plan_requested = Boolean(memorialPlan);

  if (existingCP) {
    // Update existing care plan
    const { error } = await supabase
      .schema("orders")
      .from("care_plans")
      .update(cpData)
      .eq("id", existingCP.id);

    if (error) {
      return jsonResponse({ error: "Failed to update care plan", details: error }, 500);
    }

    return jsonResponse({
      success: true,
      type: "careplan_updated",
      care_plan_id: existingCP.id,
      order_id: orderId,
      pet_id: petId,
    });
  } else {
    // Create new care plan
    const { data: newCP, error } = await supabase
      .schema("orders")
      .from("care_plans")
      .insert({
        order_id: orderId,
        ...cpData,
      })
      .select("id")
      .single();

    if (error) {
      return jsonResponse({ error: "Failed to create care plan", details: error }, 500);
    }

    return jsonResponse({
      success: true,
      type: "careplan_created",
      care_plan_id: newCP.id,
      order_id: orderId,
      pet_id: petId,
    });
  }
}

// ── Main Handler ─────────────────────────────────────────────

Deno.serve(async (req) => {
  // Only accept POST
  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  // Parse query params for routing
  const url = new URL(req.url);
  const formType = url.searchParams.get("type");

  if (!formType) {
    return jsonResponse(
      { error: "Missing ?type= parameter. Use: direct, partner, or careplan" },
      400
    );
  }

  // Parse Fillout webhook payload
  // Fillout sends: { "submission": { "questions": [...] } }
  // Each question has: { "name": "Field Name", "value": "answer" }
  let body: any;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: "Invalid JSON body" }, 400);
  }

  // Fillout webhook format: body.submission.questions[]
  // Each item: { id, name, value, type }
  const fields = body?.submission?.questions || body?.questions || body?.fields || [];

  if (!fields.length) {
    return jsonResponse(
      { error: "No form fields found in payload. Expected Fillout webhook format." },
      400
    );
  }

  try {
    switch (formType) {
      case "direct":
        return await handleIntake(fields, "direct", null);

      case "partner": {
        const code = url.searchParams.get("code");
        if (!code) {
          return jsonResponse(
            { error: "Partner intake requires ?code= parameter (e.g., LOVT)" },
            400
          );
        }
        return await handleIntake(fields, "partner", code);
      }

      case "careplan": {
        const petId = url.searchParams.get("pet");
        if (!petId) {
          return jsonResponse(
            { error: "Care plan requires ?pet= parameter (Airtable ID or Supabase UUID)" },
            400
          );
        }
        return await handleCarePlan(fields, petId);
      }

      default:
        return jsonResponse(
          { error: `Unknown form type: ${formType}. Use: direct, partner, or careplan` },
          400
        );
    }
  } catch (err) {
    console.error("Webhook processing error:", err);
    return jsonResponse({ error: "Internal server error", message: String(err) }, 500);
  }
});
