import { createClient } from 'npm:@supabase/supabase-js@2'
import webpush from 'npm:web-push@3.6.7'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

interface BroadcastRequest {
  title: string
  body: string
  url?: string
  category?: 'NEW_MODULE' | 'UPDATE' | 'MAINTENANCE' | 'INFO'
  target_type?: 'ALL' | 'ROLES' | 'OUTLETS'
  target_roles?: number[]
  target_outlets?: string[]
  send_push?: boolean
}

interface PushSubscriptionRow {
  id: string
  user_id: string
  endpoint: string
  p256dh: string
  auth: string
}

const VALID_CATEGORIES = new Set(['NEW_MODULE', 'UPDATE', 'MAINTENANCE', 'INFO'])
const VALID_TARGET_TYPES = new Set(['ALL', 'ROLES', 'OUTLETS'])

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
    const vapidPublicKey = Deno.env.get('VAPID_PUBLIC_KEY')
    const vapidPrivateKey = Deno.env.get('VAPID_PRIVATE_KEY')
    const vapidSubject = Deno.env.get('VAPID_SUBJECT') || 'mailto:admin@zenfamilyspa.com'

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
      .select('uid, user_role, full_name, email')
      .eq('uid', callerUid)
      .maybeSingle()

    if (profileErr || !profile || Number(profile.user_role) !== 8) {
      return jsonResponse(
        { error: 'Akses ditolak. Hanya SUPERUSER (Role ID 8) yang dapat mengirim pengumuman.' },
        403
      )
    }

    // 3. Parse and validate body
    const payload = (await req.json()) as BroadcastRequest
    const title = (payload.title || '').trim()
    const body = (payload.body || '').trim()
    const rawUrl = (payload.url || '/dashboard').trim()
    const url = rawUrl.startsWith('/') ? rawUrl : '/dashboard'
    const category = VALID_CATEGORIES.has(payload.category || '')
      ? payload.category!
      : 'NEW_MODULE'
    const targetType = VALID_TARGET_TYPES.has(payload.target_type || '')
      ? payload.target_type!
      : 'ALL'
    const targetRoles =
      targetType === 'ROLES' && Array.isArray(payload.target_roles)
        ? payload.target_roles.map(Number).filter((n) => Number.isInteger(n) && n > 0)
        : null
    const targetOutlets =
      targetType === 'OUTLETS' && Array.isArray(payload.target_outlets)
        ? payload.target_outlets.map((s) => String(s).trim()).filter(Boolean)
        : null
    const sendPush = payload.send_push !== false

    if (!title || title.length > 120) {
      return jsonResponse({ error: 'Judul pengumuman wajib diisi (maks. 120 karakter).' }, 400)
    }
    if (!body || body.length > 500) {
      return jsonResponse({ error: 'Isi pesan pengumuman wajib diisi (maks. 500 karakter).' }, 400)
    }
    if (targetType === 'ROLES' && (!targetRoles || targetRoles.length === 0)) {
      return jsonResponse({ error: 'Pilih minimal satu Role tujuan.' }, 400)
    }
    if (targetType === 'OUTLETS' && (!targetOutlets || targetOutlets.length === 0)) {
      return jsonResponse({ error: 'Pilih minimal satu Outlet tujuan.' }, 400)
    }

    // 4. Insert announcement record first (immediately powers In-App Notification Bell)
    const createdByName = profile.full_name || profile.email || 'SUPERUSER'
    const { data: announcement, error: insertErr } = await supabaseAdmin
      .from('whm_announcements')
      .insert({
        title,
        body,
        url,
        category,
        target_type: targetType,
        target_roles: targetRoles,
        target_outlets: targetOutlets,
        send_push: sendPush,
        created_by: callerUid,
        created_by_name: createdByName,
      })
      .select('*')
      .single()

    if (insertErr || !announcement) {
      return jsonResponse(
        { error: `Gagal menyimpan pengumuman: ${insertErr?.message || 'unknown'}` },
        500
      )
    }

    let totalTargeted = 0
    let sentCount = 0
    let failedCount = 0
    let cleanedCount = 0

    // 5. Fan-out Web Push notifications if enabled
    if (sendPush) {
      if (!vapidPublicKey || !vapidPrivateKey) {
        return jsonResponse(
          {
            success: true,
            warning: 'Pengumuman tersimpan di In-App, tetapi kunci VAPID belum terkonfigurasi.',
            announcement,
            stats: { total_targeted: 0, sent_count: 0, failed_count: 0, cleaned_count: 0 },
          },
          200
        )
      }

      webpush.setVapidDetails(vapidSubject, vapidPublicKey, vapidPrivateKey)

      let targetUserIds: string[] | null = null
      if (targetType === 'ROLES' && targetRoles) {
        const { data: roleUsers, error: roleErr } = await supabaseAdmin
          .from('users_profile')
          .select('uid')
          .in('user_role', targetRoles)
        if (roleErr) throw roleErr
        targetUserIds = (roleUsers || []).map((r: { uid: string }) => r.uid)
      } else if (targetType === 'OUTLETS' && targetOutlets) {
        const { data: outletUsers, error: outletErr } = await supabaseAdmin
          .from('users_profile')
          .select('uid')
          .in('kode_outlet', targetOutlets)
        if (outletErr) throw outletErr
        targetUserIds = (outletUsers || []).map((r: { uid: string }) => r.uid)
      }

      let subscriptions: PushSubscriptionRow[] = []
      if (targetUserIds === null) {
        const { data: subs, error: subErr } = await supabaseAdmin
          .from('whm_push_subscriptions')
          .select('id, user_id, endpoint, p256dh, auth')
          .eq('is_active', true)
        if (subErr) throw subErr
        subscriptions = (subs || []) as PushSubscriptionRow[]
      } else if (targetUserIds.length > 0) {
        const USER_ID_CHUNK_SIZE = 100
        for (let i = 0; i < targetUserIds.length; i += USER_ID_CHUNK_SIZE) {
          const idChunk = targetUserIds.slice(i, i + USER_ID_CHUNK_SIZE)
          const { data: subs, error: subErr } = await supabaseAdmin
            .from('whm_push_subscriptions')
            .select('id, user_id, endpoint, p256dh, auth')
            .eq('is_active', true)
            .in('user_id', idChunk)
          if (subErr) throw subErr
          if (subs && subs.length > 0) {
            subscriptions.push(...(subs as PushSubscriptionRow[]))
          }
        }
      }

      totalTargeted = subscriptions.length
      const staleIds: string[] = []
      const pushBody = JSON.stringify({
        title,
        body,
        url,
        category,
        announcementId: announcement.id,
        icon: '/pwa-192x192.png',
        badge: '/pwa-192x192.png',
        tag: `zen-whm-${announcement.id}`,
      })

      const CHUNK_SIZE = 20
      for (let i = 0; i < subscriptions.length; i += CHUNK_SIZE) {
        const chunk = subscriptions.slice(i, i + CHUNK_SIZE)
        const results = await Promise.allSettled(
          chunk.map((sub) =>
            webpush.sendNotification(
              {
                endpoint: sub.endpoint,
                keys: { p256dh: sub.p256dh, auth: sub.auth },
              },
              pushBody,
              { TTL: 86400, timeout: 10000 }
            )
          )
        )

        results.forEach((res, idx) => {
          if (res.status === 'fulfilled') {
            sentCount++
          } else {
            failedCount++
            const errObj = res.reason as { statusCode?: number } | undefined
            if (errObj?.statusCode === 404 || errObj?.statusCode === 410) {
              staleIds.push(chunk[idx].id)
            }
          }
        })
      }

      if (staleIds.length > 0) {
        const { error: cleanErr } = await supabaseAdmin
          .from('whm_push_subscriptions')
          .update({ is_active: false, updated_at: new Date().toISOString() })
          .in('id', staleIds)
        if (!cleanErr) {
          cleanedCount = staleIds.length
        }
      }

      await supabaseAdmin
        .from('whm_announcements')
        .update({
          push_total_targeted: totalTargeted,
          push_sent_count: sentCount,
          push_failed_count: failedCount,
          push_cleaned_count: cleanedCount,
        })
        .eq('id', announcement.id)
    }

    return jsonResponse({
      success: true,
      announcement: {
        ...announcement,
        push_total_targeted: totalTargeted,
        push_sent_count: sentCount,
        push_failed_count: failedCount,
        push_cleaned_count: cleanedCount,
      },
      stats: {
        total_targeted: totalTargeted,
        sent_count: sentCount,
        failed_count: failedCount,
        cleaned_count: cleanedCount,
      },
    })
  } catch (err) {
    const message = err instanceof Error ? err.message : 'Terjadi kesalahan internal server.'
    return jsonResponse({ error: message }, 500)
  }
})
