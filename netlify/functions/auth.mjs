const emailForUsername = (username) => `${username.toLowerCase()}@users.sinna.invalid`;

const reply = (statusCode, body) => new Response(JSON.stringify(body), {
    status: statusCode,
    headers: { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });

const readJson = async (response) => {
  const text = await response.text();
  if (!text) return {};
  try {
    return JSON.parse(text);
  } catch {
    return { message: text };
  }
};

const serverConfig = () => {
  const url = process.env.SUPABASE_URL?.replace(/\/+$/, "");
  const anonKey = process.env.SUPABASE_PUBLISHABLE_KEY || process.env.SUPABASE_ANON_KEY;
  const serviceKey = process.env.SUPABASE_SECRET_KEY || process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !anonKey || !serviceKey) {
    throw new Error("أكمل SUPABASE_URL وSUPABASE_PUBLISHABLE_KEY وSUPABASE_SECRET_KEY في متغيرات بيئة Netlify.");
  }
  return { url, anonKey, serviceKey };
};

const callSupabase = async (url, path, { method = "GET", key, token, body, headers = {} }) => {
  const response = await fetch(`${url}${path}`, {
    method,
    headers: {
      apikey: key,
      Authorization: `Bearer ${token || key}`,
      ...(body === undefined ? {} : { "Content-Type": "application/json" }),
      ...headers,
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  return { response, data: await readJson(response) };
};

const failFrom = (data, fallback) => data.msg || data.message || data.error_description || data.error || fallback;

const profileForUser = async (config, userId) => {
  const query = new URLSearchParams({
    id: `eq.${userId}`,
    select: "id,username,full_name,role,created_at",
    limit: "1",
  });
  const { response, data } = await callSupabase(
    config.url,
    `/rest/v1/profiles?${query}`,
    { key: config.serviceKey },
  );
  if (!response.ok) throw new Error(failFrom(data, "تعذر التحقق من ملف المستخدم."));
  return Array.isArray(data) ? data[0] : undefined;
};

const profileForUsername = async (config, username) => {
  const query = new URLSearchParams({
    username: `eq.${username}`,
    select: "id",
    limit: "1",
  });
  const { response, data } = await callSupabase(
    config.url,
    `/rest/v1/profiles?${query}`,
    { key: config.serviceKey },
  );
  if (!response.ok) throw new Error(failFrom(data, "تعذر التحقق من اسم المستخدم."));
  return Array.isArray(data) ? data[0] : undefined;
};

const requireStaff = async (config, accessToken) => {
  if (typeof accessToken !== "string" || !accessToken) {
    return { error: reply(401, { error: "سجّل الدخول للمتابعة." }) };
  }

  const { response: authResponse, data: user } = await callSupabase(
    config.url,
    "/auth/v1/user",
    { key: config.anonKey, token: accessToken },
  );
  if (!authResponse.ok || !user.id) {
    return { error: reply(401, { error: "انتهت صلاحية الجلسة. سجّل الدخول مرة أخرى." }) };
  }

  const profile = await profileForUser(config, user.id);
  if (!profile || ![1, 2].includes(profile.role)) {
    return { error: reply(403, { error: "هذا الحساب غير مخوّل لدخول واجهة الموظفين." }) };
  }
  return { user, profile };
};

const handleLogin = async (config, body) => {
  const username = typeof body.username === "string" ? body.username.trim().toLowerCase() : "";
  const password = typeof body.password === "string" ? body.password : "";
  if (!/^[a-z0-9._-]{3,32}$/.test(username) || password.length < 8) {
    return reply(400, { error: "أدخل اسم مستخدم صالحاً وكلمة المرور." });
  }

  const profileIdentity = await profileForUsername(config, username);
  if (!profileIdentity) return reply(401, { error: "اسم المستخدم أو كلمة المرور غير صحيحة." });

  const { response: userResponse, data: authUserData } = await callSupabase(
    config.url,
    `/auth/v1/admin/users/${profileIdentity.id}`,
    { key: config.serviceKey },
  );
  const authEmail = authUserData.email || authUserData.user?.email;
  if (!userResponse.ok || typeof authEmail !== "string") {
    return reply(401, { error: "اسم المستخدم أو كلمة المرور غير صحيحة." });
  }

  const { response, data } = await callSupabase(
    config.url,
    "/auth/v1/token?grant_type=password",
    { method: "POST", key: config.anonKey, body: { email: authEmail, password } },
  );
  if (!response.ok) return reply(401, { error: "اسم المستخدم أو كلمة المرور غير صحيحة." });

  const profile = await profileForUser(config, data.user?.id);
  if (!profile || ![1, 2].includes(profile.role)) {
    await callSupabase(config.url, "/auth/v1/logout", {
      method: "POST", key: config.anonKey, token: data.access_token,
    });
    return reply(403, { error: "هذا الحساب غير مخوّل لدخول واجهة الموظفين." });
  }

  return reply(200, {
    session: {
      access_token: data.access_token,
      refresh_token: data.refresh_token,
      expires_at: data.expires_at,
    },
    profile,
  });
};

const handleRefresh = async (config, body) => {
  const refreshToken = typeof body.refreshToken === "string" ? body.refreshToken : "";
  if (!refreshToken) return reply(401, { error: "انتهت صلاحية الجلسة. سجّل الدخول مرة أخرى." });

  const { response, data } = await callSupabase(
    config.url,
    "/auth/v1/token?grant_type=refresh_token",
    { method: "POST", key: config.anonKey, body: { refresh_token: refreshToken } },
  );
  if (!response.ok) return reply(401, { error: "انتهت صلاحية الجلسة. سجّل الدخول مرة أخرى." });

  const profile = await profileForUser(config, data.user?.id);
  if (!profile || ![1, 2].includes(profile.role)) {
    return reply(403, { error: "هذا الحساب غير مخوّل لدخول واجهة الموظفين." });
  }
  return reply(200, {
    session: {
      access_token: data.access_token,
      refresh_token: data.refresh_token,
      expires_at: data.expires_at,
    },
    profile,
  });
};

const handleListSellers = async (config, profile) => {
  if (profile.role !== 1) return reply(403, { error: "إنشاء الحسابات متاح للمالك فقط." });
  const query = new URLSearchParams({
    role: "eq.2",
    select: "id,username,full_name,created_at",
    order: "created_at.desc",
  });
  const { response, data } = await callSupabase(config.url, `/rest/v1/profiles?${query}`, {
    key: config.serviceKey,
  });
  if (!response.ok) return reply(502, { error: failFrom(data, "تعذر تحميل حسابات البائعين.") });
  return reply(200, { sellers: data });
};

const handleCreateSeller = async (config, profile, body) => {
  if (profile.role !== 1) return reply(403, { error: "إنشاء الحسابات متاح للمالك فقط." });

  const fullName = typeof body.fullName === "string" ? body.fullName.trim() : "";
  const username = typeof body.username === "string" ? body.username.trim().toLowerCase() : "";
  const password = typeof body.password === "string" ? body.password : "";
  if (fullName.length < 2 || fullName.length > 100) {
    return reply(400, { error: "أدخل اسم البائع بطول من حرفين إلى 100 حرف." });
  }
  if (!/^[a-z0-9._-]{3,32}$/.test(username)) {
    return reply(400, { error: "اسم المستخدم يجب أن يكون من 3 إلى 32 حرفاً إنجليزياً أو رقماً أو . _ -." });
  }
  if (password.length < 10 || password.length > 72) {
    return reply(400, { error: "كلمة مرور البائع يجب أن تكون بطول 10 أحرف على الأقل." });
  }

  const existingQuery = new URLSearchParams({
    username: `eq.${username}`,
    select: "id",
    limit: "1",
  });
  const { response: duplicateResponse, data: duplicateData } = await callSupabase(
    config.url,
    `/rest/v1/profiles?${existingQuery}`,
    { key: config.serviceKey },
  );
  if (!duplicateResponse.ok) return reply(502, { error: "تعذر التحقق من اسم المستخدم." });
  if (duplicateData.length) return reply(409, { error: "اسم المستخدم مستخدم بالفعل؛ اختر اسماً آخر." });

  const { response: createResponse, data: created } = await callSupabase(
    config.url,
    "/auth/v1/admin/users",
    {
      method: "POST",
      key: config.serviceKey,
      body: {
        email: emailForUsername(username),
        email_confirm: true,
        password,
        user_metadata: { username, full_name: fullName },
      },
    },
  );
  if (!createResponse.ok) {
    return reply(createResponse.status === 422 ? 409 : 502, {
      error: createResponse.status === 422
        ? "تعذر إنشاء الحساب بهذا الاسم. قد يكون اسم المستخدم مستخدماً بالفعل."
        : failFrom(created, "تعذر إنشاء حساب البائع."),
    });
  }

  const query = new URLSearchParams({ id: `eq.${created.id}` });
  const { response: profileResponse, data: profileData } = await callSupabase(
    config.url,
    `/rest/v1/profiles?${query}`,
    {
      method: "PATCH",
      key: config.serviceKey,
      body: { username, full_name: fullName, role: 2 },
      headers: { Prefer: "return=representation" },
    },
  );
  if (!profileResponse.ok) {
    await callSupabase(config.url, `/auth/v1/admin/users/${created.id}`, {
      method: "DELETE", key: config.serviceKey,
    });
    return reply(502, { error: failFrom(profileData, "فشل حفظ ملف البائع؛ أُلغي إنشاء الحساب.") });
  }

  return reply(201, { seller: Array.isArray(profileData) ? profileData[0] : undefined });
};

const handleUpdateSeller = async (config, profile, body) => {
  if (profile.role !== 1) return reply(403, { error: "تعديل حسابات البائعين متاح للمالك فقط." });

  const userId = typeof body.userId === "string" ? body.userId : "";
  const fullName = typeof body.fullName === "string" ? body.fullName.trim() : "";
  const username = typeof body.username === "string" ? body.username.trim().toLowerCase() : "";
  const password = typeof body.password === "string" ? body.password : "";
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(userId)) {
    return reply(400, { error: "معرّف حساب البائع غير صالح." });
  }
  if (fullName.length < 2 || fullName.length > 100) {
    return reply(400, { error: "أدخل اسم بائع بطول من حرفين إلى 100 حرف." });
  }
  if (!/^[a-z0-9._-]{3,32}$/.test(username)) {
    return reply(400, { error: "اسم المستخدم يجب أن يكون من 3 إلى 32 حرفاً إنجليزياً أو رقماً أو . _ -." });
  }
  if (password && (password.length < 10 || password.length > 72)) {
    return reply(400, { error: "كلمة المرور الجديدة يجب أن تكون بطول 10 إلى 72 حرفاً." });
  }

  const seller = await profileForUser(config, userId);
  if (!seller || seller.role !== 2) return reply(404, { error: "حساب البائع غير موجود." });

  const existing = await profileForUsername(config, username);
  if (existing && existing.id !== seller.id) {
    return reply(409, { error: "اسم المستخدم مستخدم بالفعل؛ اختر اسماً آخر." });
  }

  const profilePath = `/rest/v1/profiles?${new URLSearchParams({ id: `eq.${userId}` })}`;
  const { response: profileResponse, data: profileData } = await callSupabase(config.url, profilePath, {
    method: "PATCH",
    key: config.serviceKey,
    body: { username, full_name: fullName },
    headers: { Prefer: "return=representation" },
  });
  if (!profileResponse.ok) return reply(502, { error: failFrom(profileData, "تعذر حفظ بيانات البائع.") });

  if (password) {
    const { response: passwordResponse, data: passwordData } = await callSupabase(
      config.url,
      `/auth/v1/admin/users/${userId}`,
      { method: "PUT", key: config.serviceKey, body: { password } },
    );
    if (!passwordResponse.ok) {
      const { response: rollbackResponse } = await callSupabase(config.url, profilePath, {
        method: "PATCH",
        key: config.serviceKey,
        body: { username: seller.username, full_name: seller.full_name },
      });
      const error = failFrom(passwordData, "تعذر تحديث كلمة مرور البائع.");
      return reply(502, {
        error: rollbackResponse.ok ? error : `${error} تعذر التراجع عن تحديث البيانات؛ راجع الحساب يدوياً.`,
      });
    }
  }

  return reply(200, { seller: Array.isArray(profileData) ? profileData[0] : undefined, passwordUpdated: !!password });
};

export default async (request) => {
  if (request.method !== "POST") return reply(405, { error: "الطريقة غير مدعومة." });

  let body;
  try {
    body = await request.json();
  } catch {
    return reply(400, { error: "صيغة الطلب غير صالحة." });
  }
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return reply(400, { error: "بيانات الطلب غير صالحة." });
  }

  let config;
  try {
    config = serverConfig();
  } catch (error) {
    return reply(503, { error: error.message });
  }

  try {
    if (body.action === "login") return await handleLogin(config, body);
    if (body.action === "refresh") return await handleRefresh(config, body);
    if (body.action === "me") {
      const auth = await requireStaff(config, body.accessToken);
      return auth.error || reply(200, { profile: auth.profile });
    }
    if (body.action === "logout") {
      if (typeof body.accessToken !== "string" || !body.accessToken) {
        return reply(400, { error: "الجلسة غير موجودة." });
      }
      const { response } = await callSupabase(config.url, "/auth/v1/logout", {
        method: "POST", key: config.anonKey, token: body.accessToken,
      });
      return response.ok ? reply(200, { ok: true }) : reply(502, { error: "تعذر إغلاق الجلسة على الخادم." });
    }

    const auth = await requireStaff(config, body.accessToken);
    if (auth.error) return auth.error;
    if (body.action === "listSellers") return await handleListSellers(config, auth.profile);
    if (body.action === "createSeller") return await handleCreateSeller(config, auth.profile, body);
    if (body.action === "updateSeller") return await handleUpdateSeller(config, auth.profile, body);
    return reply(400, { error: "العملية المطلوبة غير معروفة." });
  } catch (error) {
    if (error instanceof TypeError) {
      return reply(502, { error: "تعذر الاتصال بخدمة Supabase. تحقق من إعدادات المشروع واتصال الشبكة." });
    }
    throw error;
  }
};
