import { createClient } from 'npm:@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

interface AdminResetPasswordRequest {
  target_uid?: unknown
  new_password?: unknown
  revoke_sessions?: unknown
}

const UUID_REGEX = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const CONTROL_CHAR_REGEX = /[\x00-\x1F\x7F]/

function jsonResponse(payload: unknown, status = 200): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  })
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  if (req.method !== 'POST') {
    return jsonResponse({ error: 'Metode tidak diizinkan. Gunakan POST.' }, 405)
  }

  try {
    const supabaseUrl = Deno.env.get('SUPABASE_URL')
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')

    if (!supabaseUrl || !serviceRoleKey) {
      return jsonResponse({ error: 'Konfigurasi server Supabase belum lengkap.' }, 500)
    }

    const authHeader = req.headers.get('Authorization') || ''
    const token = authHeader.replace(/^Bearer\s+/i, '').trim()
    if (!token) {
      return jsonResponse({ error: 'Token otorisasi tidak ditemukan.' }, 401)
    }

    const supabaseAdmin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    })

    // 1. Verify caller JWT
    const { data: userData, error: userErr } = await supabaseAdmin.auth.getUser(token)
    if (userErr || !userData?.user) {
      return jsonResponse({ error: 'Sesi login tidak valid atau telah berakhir.' }, 401)
    }
    const callerUid = userData.user.id

    // 2. Strict Role ID 8 (SUPERUSER) check
    const { data: profile, error: profileErr } = await supabaseAdmin
      .from('users_profile')
      .select('uid, user_role, role_user, full_name, email, is_active')
      .eq('uid', callerUid)
      .maybeSingle()

    const effectiveRole = Number(profile?.user_role ?? profile?.role_user)
    if (profileErr || !profile || effectiveRole !== 8 || profile.is_active === false) {
      return jsonResponse(
        { error: 'Akses ditolak. Hanya SUPERUSER (Role ID 8) yang dapat mereset kata sandi pengguna.' },
        403
      )
    }

    // 3. Parse and validate request body
    let payload: AdminResetPasswordRequest
    try {
      payload = (await req.json()) as AdminResetPasswordRequest
    } catch {
      return jsonResponse({ error: 'Format payload JSON tidak valid.' }, 400)
    }

    const targetUid = typeof payload.target_uid === 'string' ? payload.target_uid.trim() : ''
    if (!targetUid || !UUID_REGEX.test(targetUid)) {
      return jsonResponse({ error: 'ID pengguna target (target_uid) tidak valid.' }, 400)
    }

    if (targetUid.toLowerCase() === callerUid.toLowerCase()) {
      return jsonResponse(
        { error: 'Gunakan menu Ubah Kata Sandi untuk mengganti kata sandi akun Anda sendiri.' },
        400
      )
    }

    if (typeof payload.new_password !== 'string') {
      return jsonResponse({ error: 'Kata sandi baru wajib diisi.' }, 400)
    }

    const newPassword = payload.new_password
    if (newPassword !== newPassword.trim()) {
      return jsonResponse(
        { error: 'Kata sandi baru tidak boleh diawali atau diakhiri spasi.' },
        400
      )
    }
    if (newPassword.length < 8 || newPassword.length > 64) {
      return jsonResponse(
        { error: 'Kata sandi baru harus terdiri dari 8 hingga 64 karakter.' },
        400
      )
    }
    if (CONTROL_CHAR_REGEX.test(newPassword)) {
      return jsonResponse(
        { error: 'Kata sandi baru tidak boleh mengandung karakter kontrol.' },
        400
      )
    }

    const revokeSessions = payload.revoke_sessions !== false

    // 4. Verify target user & authentication provider
    const { data: targetData, error: targetErr } = await supabaseAdmin.auth.admin.getUserById(targetUid)
    if (targetErr || !targetData?.user) {
      return jsonResponse(
        { error: 'Akun pengguna target tidak ditemukan di sistem autentikasi.' },
        404
      )
    }

    const targetUser = targetData.user
    const providerSet = new Set<string>()
    if (typeof targetUser.app_metadata?.provider === 'string') {
      providerSet.add(targetUser.app_metadata.provider.toLowerCase())
    }
    if (Array.isArray(targetUser.app_metadata?.providers)) {
      for (const p of targetUser.app_metadata.providers) {
        if (typeof p === 'string') providerSet.add(p.toLowerCase())
      }
    }
    if (Array.isArray(targetUser.identities)) {
      for (const idn of targetUser.identities) {
        if (typeof idn?.provider === 'string') providerSet.add(idn.provider.toLowerCase())
      }
    }

    if (!providerSet.has('email')) {
      return jsonResponse(
        {
          error:
            'Akun ini hanya menggunakan login Google OAuth dan tidak memiliki kata sandi email. Pengguna cukup masuk dengan tombol Masuk dengan Google.',
        },
        400
      )
    }

    // 5. Update password officially via GoTrue Admin API
    const { error: updateErr } = await supabaseAdmin.auth.admin.updateUserById(targetUid, {
      password: newPassword,
    })

    if (updateErr) {
      return jsonResponse(
        { error: `Gagal memperbarui kata sandi: ${updateErr.message}` },
        500
      )
    }

    // 6. Revoke active sessions if requested (non-fatal if revocation fails)
    let sessionsRevoked = false
    let revokedSessionCount = 0
    let warning: string | undefined

    if (revokeSessions) {
      const { data: revokeCount, error: revokeErr } = await supabaseAdmin.rpc(
        'admin_revoke_user_sessions',
        { p_target_uid: targetUid }
      )
      if (revokeErr) {
        sessionsRevoked = false
        warning =
          'Kata sandi berhasil direset, namun pencabutan sesi aktif gagal dijalankan. Minta pengguna keluar lalu masuk kembali.'
      } else {
        sessionsRevoked = true
        revokedSessionCount = Number(revokeCount) || 0
      }
    }

    // 7. Best-effort immutable audit log (never logs password)
    const targetEmail = targetUser.email || '-'
    const resetByName = profile.full_name || profile.email || 'SUPERUSER'
    await supabaseAdmin.from('whm_password_reset_logs').insert({
      target_uid: targetUid,
      target_email: targetEmail,
      reset_by_uid: callerUid,
      reset_by_name: resetByName,
      sessions_revoked: sessionsRevoked,
    })

    return jsonResponse({
      success: true,
      message: `Kata sandi untuk ${targetEmail} berhasil direset.`,
      target_uid: targetUid,
      target_email: targetEmail,
      sessions_revoked: sessionsRevoked,
      revoked_session_count: revokedSessionCount,
      ...(warning ? { warning } : {}),
      updated_at: new Date().toISOString(),
    })
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Terjadi kesalahan internal server.'
    return jsonResponse({ error: message }, 500)
  }
})
