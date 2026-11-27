const nodemailer = require('nodemailer');

const SUPABASE_URL = 'https://izrjdhuosxtqteftzkhd.supabase.co';
const SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Iml6cmpkaHVvc3h0cXRlZnR6a2hkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzY2MjQ3NDUsImV4cCI6MjA5MjIwMDc0NX0.89tLGBgY-Wwy8S-zN1LrZHhfp-AZGLgdOct-L8q7e8M';

function cleanHeader(value) {
    return String(value ?? '').replace(/[\r\n]+/g, ' ').trim();
}

function centralAppointmentTime(value) {
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) throw new Error('invalid appointment time');
    const dateText = new Intl.DateTimeFormat('en-US', {
        timeZone: 'America/Chicago',
        weekday: 'short',
        month: 'short',
        day: 'numeric'
    }).format(date);
    const timeText = new Intl.DateTimeFormat('en-US', {
        timeZone: 'America/Chicago',
        hour: 'numeric',
        minute: '2-digit',
        hour12: true
    }).format(date);
    return `${dateText} at ${timeText}`;
}

function centralAppointmentSubjectTime(value) {
    const date = new Date(value);
    const dateText = new Intl.DateTimeFormat('en-US', {
        timeZone: 'America/Chicago',
        weekday: 'short',
        month: 'short',
        day: 'numeric'
    }).format(date);
    const timeText = new Intl.DateTimeFormat('en-US', {
        timeZone: 'America/Chicago', hour: 'numeric', minute: '2-digit', hour12: true
    }).format(date);
    return `${dateText}, ${timeText}`;
}

module.exports = async function appointmentEmail(req, res) {
    res.setHeader('Cache-Control', 'no-store');
    if (req.method !== 'POST') return res.status(405).json({ error: 'method_not_allowed' });

    const body = req.body && typeof req.body === 'object' ? req.body : {};
    const id = body.id;
    const token = String(body.token || '');
    if (!Number.isSafeInteger(id) || id < 1 || !/^[0-9a-f]{36}$/.test(token)) {
        return res.status(400).json({ error: 'invalid_request' });
    }

    const gmailUser = cleanHeader(process.env.GMAIL_USER);
    const gmailPassword = String(process.env.GMAIL_APP_PASSWORD || '').replace(/\s/g, '');
    if (!gmailUser || !gmailPassword) {
        return res.status(502).json({ error: 'email_unavailable' });
    }

    try {
        const headers = {
            apikey: SUPABASE_KEY,
            Authorization: `Bearer ${SUPABASE_KEY}`,
            'Content-Type': 'application/json'
        };
        if (req.headers?.['x-forwarded-for']) {
            headers['x-forwarded-for'] = req.headers['x-forwarded-for'];
        }
        const response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/julis_appointment_for_email`, {
            method: 'POST',
            headers,
            body: JSON.stringify({ p_id: id, p_token: token })
        });
        if (!response.ok) return res.status(502).json({ error: 'email_unavailable' });
        const appointment = await response.json();
        if (appointment === null) return res.status(404).json({ error: 'not_found' });
        if (!appointment || typeof appointment !== 'object') {
            return res.status(502).json({ error: 'email_unavailable' });
        }

        const name = cleanHeader(appointment.name);
        const phone = cleanHeader(appointment.phone);
        const customerEmail = cleanHeader(appointment.email);
        const centralTime = centralAppointmentTime(appointment.start_at);
        const subjectTime = centralAppointmentSubjectTime(appointment.start_at);
        const sender = `Juli's Studios <${gmailUser}>`;
        const transport = nodemailer.createTransport({
            host: 'smtp.gmail.com',
            port: 465,
            secure: true,
            auth: { user: gmailUser, pass: gmailPassword }
        });
        await transport.sendMail({
            from: sender,
            to: customerEmail,
            subject: "Your appointment with Juli's Studios is confirmed",
            text: `Hi ${name},\n\nYour appointment is confirmed for ${centralTime} Central Time.\nDuration: 1 hour.\n\nNeed to change it? Reply to this email.\n\nJuli's Studios`
        });
        await transport.sendMail({
            from: sender,
            to: gmailUser,
            replyTo: customerEmail,
            subject: `New appointment: ${name} — ${subjectTime}`,
            text: `New appointment\n\nName: ${name}\nPhone: ${phone}\nEmail: ${customerEmail}\nTime: ${centralTime} Central Time\nDuration: 1 hour`
        });
        return res.status(200).json({ sent: true });
    } catch {
        return res.status(502).json({ error: 'email_unavailable' });
    }
};
