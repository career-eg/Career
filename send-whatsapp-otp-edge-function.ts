// Supabase Edge Function: send-whatsapp-otp
// Deploy path: supabase/functions/send-whatsapp-otp/index.ts
//
// This function sends OTP codes to the user's WhatsApp. It supports multiple
// WhatsApp providers — configure the one you have credentials for by setting
// the corresponding environment variables in your Supabase project:
//   Settings → Edge Functions → Environment Variables
//
// Provider options (pick one and set its env vars):
//
// 1) Meta WhatsApp Cloud API (recommended — free tier of 1000 msg/day):
//    WHATSAPP_PROVIDER=meta
//    META_ACCESS_TOKEN=<your-permanent-access-token>
//    META_PHONE_NUMBER_ID=<your-whatsapp-business-phone-id>
//    META_TEMPLATE_NAME=careerk_otp
//
// 2) Twilio WhatsApp:
//    WHATSAPP_PROVIDER=twilio
//    TWILIO_ACCOUNT_SID=<...>
//    TWILIO_AUTH_TOKEN=<...>
//    TWILIO_WHATSAPP_FROM=whatsapp:+201205409238
//
// 3) Green API:
//    WHATSAPP_PROVIDER=green
//    GREEN_INSTANCE_ID=<...>
//    GREEN_API_TOKEN=<...>
//
// Deploy:  supabase functions deploy send-whatsapp-otp
// Then configure the DB to call this function:
//   alter database postgres set "app.whatsapp_edge_function_url" =
//     'https://<project-ref>.functions.supabase.co/send-whatsapp-otp';
//   alter database postgres set "app.whatsapp_edge_function_key" =
//     '<supabase-anon-or-service-role-key>';

// deno-lint-ignore-file no-explicit-any
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

const OTP_MESSAGE_AR = (code: string) =>
  `كود التحقق بتاعك في CareerK هو: ${code}
الكود صالح لمدة 10 دقايق.
لو مش أنت اللي طلبته، تجاهل الرسالة.`;

async function sendViaMetaCloudAPI(phone: string, code: string): Promise<Response> {
  const token = Deno.env.get("META_ACCESS_TOKEN")!;
  const phoneNumberId = Deno.env.get("META_PHONE_NUMBER_ID")!;
  const templateName = Deno.env.get("META_TEMPLATE_NAME") || "careerk_otp";

  // Meta requires numbers in E.164 without the plus for the API body
  const to = phone.replace(/[^0-9]/g, "");

  const url = `https://graph.facebook.com/v18.0/${phoneNumberId}/messages`;
  const body = {
    messaging_product: "whatsapp",
    to,
    type: "template",
    template: {
      name: templateName,
      language: { code: "ar" },
      components: [
        {
          type: "body",
          parameters: [{ type: "text", text: code }],
        },
        {
          type: "button",
          sub_type: "url",
          index: "0",
          parameters: [{ type: "text", text: code }],
        },
      ],
    },
  };

  return await fetch(url, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(body),
  });
}

async function sendViaTwilio(phone: string, code: string): Promise<Response> {
  const accountSid = Deno.env.get("TWILIO_ACCOUNT_SID")!;
  const authToken = Deno.env.get("TWILIO_AUTH_TOKEN")!;
  const from = Deno.env.get("TWILIO_WHATSAPP_FROM")!;
  const to = `whatsapp:+${phone.replace(/[^0-9]/g, "")}`;
  const auth = btoa(`${accountSid}:${authToken}`);

  return await fetch(
    `https://api.twilio.com/2010-04-01/Accounts/${accountSid}/Messages.json`,
    {
      method: "POST",
      headers: {
        "Authorization": `Basic ${auth}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: new URLSearchParams({
        From: from,
        To: to,
        Body: OTP_MESSAGE_AR(code),
      }).toString(),
    },
  );
}

async function sendViaGreenAPI(phone: string, code: string): Promise<Response> {
  const instanceId = Deno.env.get("GREEN_INSTANCE_ID")!;
  const apiToken = Deno.env.get("GREEN_API_TOKEN")!;
  const chatId = `${phone.replace(/[^0-9]/g, "")}@c.us`;

  return await fetch(
    `https://api.green-api.com/waInstance${instanceId}/sendMessage/${apiToken}`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        chatId,
        message: OTP_MESSAGE_AR(code),
      }),
    },
  );
}

serve(async (req) => {
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }

  try {
    const { phone, code, template: _template } = await req.json();
    if (!phone || !code) {
      return new Response(
        JSON.stringify({ error: "phone and code required" }),
        { status: 400, headers: { "Content-Type": "application/json" } },
      );
    }

    const provider = Deno.env.get("WHATSAPP_PROVIDER") || "meta";
    let response: Response;

    switch (provider) {
      case "meta":
        response = await sendViaMetaCloudAPI(phone, code);
        break;
      case "twilio":
        response = await sendViaTwilio(phone, code);
        break;
      case "green":
        response = await sendViaGreenAPI(phone, code);
        break;
      default:
        return new Response(
          JSON.stringify({ error: `Unknown provider: ${provider}` }),
          { status: 500, headers: { "Content-Type": "application/json" } },
        );
    }

    const responseText = await response.text();
    if (!response.ok) {
      console.error(
        `WhatsApp send failed [${provider}]`,
        response.status,
        responseText,
      );
      return new Response(
        JSON.stringify({
          ok: false,
          provider,
          status: response.status,
          error: responseText,
        }),
        {
          status: response.status,
          headers: { "Content-Type": "application/json" },
        },
      );
    }

    return new Response(
      JSON.stringify({ ok: true, provider }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  } catch (err) {
    console.error("send-whatsapp-otp error", err);
    return new Response(
      JSON.stringify({ ok: false, error: String(err) }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }
});
