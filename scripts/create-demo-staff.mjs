const projectUrl = process.env.SUPABASE_URL?.replace(/\/+$/, "");
const serviceKey = process.env.SUPABASE_SECRET_KEY || process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!projectUrl || !serviceKey) {
  console.error("Set SUPABASE_URL and SUPABASE_SECRET_KEY in your local environment first.");
  process.exit(1);
}

const temporaryPassword = "12345678";
const demoAccounts = [
  { username: "owner_demo", fullName: "OH Demo Owner", role: 1 },
  { username: "seller_demo", fullName: "OH Demo Seller", role: 2 },
];

async function request(path, { method = "GET", body, prefer } = {}) {
  const response = await fetch(`${projectUrl}${path}`, {
    method,
    headers: {
      apikey: serviceKey,
      Authorization: `Bearer ${serviceKey}`,
      ...(body === undefined ? {} : { "Content-Type": "application/json" }),
      ...(prefer ? { Prefer: prefer } : {}),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  const text = await response.text();
  let data;
  try {
    data = text ? JSON.parse(text) : null;
  } catch {
    data = { message: text };
  }
  if (!response.ok) {
    throw new Error(data?.msg || data?.message || `Supabase request failed (${response.status}).`);
  }
  return data;
}

async function findAuthUser(email) {
  const perPage = 100;
  for (let page = 1; ; page += 1) {
    const result = await request(`/auth/v1/admin/users?page=${page}&per_page=${perPage}`);
    const users = result.users || [];
    const existing = users.find((user) => user.email?.toLowerCase() === email.toLowerCase());
    if (existing) return existing;
    if (users.length < perPage) return null;
  }
}

async function ensureDemoAccount(account) {
  const email = `${account.username}@users.sinna.invalid`;
  const existing = await findAuthUser(email);
  const result = existing
    ? await request(`/auth/v1/admin/users/${existing.id}`, {
      method: "PUT",
      body: {
        password: temporaryPassword,
        email_confirm: true,
        user_metadata: { username: account.username, full_name: account.fullName },
      },
    })
    : await request("/auth/v1/admin/users", {
      method: "POST",
      body: {
        email,
        password: temporaryPassword,
        email_confirm: true,
        user_metadata: { username: account.username, full_name: account.fullName },
      },
    });
  const user = result.user || result;
  if (!user.id) throw new Error(`Supabase did not return an id for ${account.username}.`);

  await request("/rest/v1/profiles?on_conflict=id", {
    method: "POST",
    prefer: "resolution=merge-duplicates,return=minimal",
    body: {
      id: user.id,
      username: account.username,
      full_name: account.fullName,
      role: account.role,
    },
  });
  console.log(`Ready: username=${account.username}, role=${account.role}`);
}

try {
  for (const account of demoAccounts) await ensureDemoAccount(account);
  console.log(`Temporary password for both demo accounts: ${temporaryPassword}`);
  console.log("Change both passwords immediately after testing.");
} catch (error) {
  console.error(`Could not create demo accounts: ${error.message}`);
  process.exitCode = 1;
}
