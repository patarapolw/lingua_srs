import { Env, Mail } from './types';

export function confirmationMail(to: string, code: string): Mail {
  const shown = `${code.slice(0, 4)} ${code.slice(4)}`;
  return {
    to,
    subject: 'Your LinguaSRS confirmation code',
    text:
      `Your LinguaSRS confirmation code is ${shown}.\n\n` +
      'Enter it in the app to finish creating your sync account. It works for ' +
      "30 minutes. If you didn't ask for it, you can ignore this email.",
    html:
      `<p>Your LinguaSRS confirmation code is <strong>${shown}</strong>.</p>` +
      '<p>Enter it in the app to finish creating your sync account. It works for ' +
      "30 minutes. If you didn't ask for it, you can ignore this email.</p>",
  };
}

/** Sends through Resend, or prints the email when developing locally. */
export function createMailSender(env: Env): (mail: Mail) => Promise<void> {
  return async (mail) => {
    if (!env.RESEND_API_KEY) {
      if (env.DEV_LOG_EMAILS === 'true') {
        console.log(`[dev mail] to=${mail.to}\n${mail.text}`);
        return;
      }
      throw new Error('RESEND_API_KEY is not set');
    }
    const response = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.RESEND_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        from: env.MAIL_FROM,
        to: [mail.to],
        subject: mail.subject,
        text: mail.text,
        html: mail.html,
      }),
    });
    if (!response.ok) throw new Error(`Resend answered ${response.status}`);
  };
}
