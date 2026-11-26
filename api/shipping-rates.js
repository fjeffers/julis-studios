const SUPABASE_URL = 'https://izrjdhuosxtqteftzkhd.supabase.co';
const SUPABASE_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Iml6cmpkaHVvc3h0cXRlZnR6a2hkIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzY2MjQ3NDUsImV4cCI6MjA5MjIwMDc0NX0.89tLGBgY-Wwy8S-zN1LrZHhfp-AZGLgdOct-L8q7e8M';
const DEFAULT_PACKAGES = {
    envelope: { label: 'Padded envelope', length: 9, width: 6, height: 1, weightOz: 1 },
    small: { label: 'Small box', length: 8, width: 6, height: 4, weightOz: 4 },
    medium: { label: 'Medium box', length: 12, width: 10, height: 6, weightOz: 8 }
};
const PACKAGE_KEYS = Object.keys(DEFAULT_PACKAGES);
const MAX_PACKAGE_DIMENSION_IN = 36;
const MAX_WEIGHT_OZ = 1120;

function parseBody(body) {
    if (typeof body === 'string') {
        try {
            return JSON.parse(body);
        } catch {
            return null;
        }
    }
    return body && typeof body === 'object' && !Array.isArray(body) ? body : null;
}

function positiveNumber(value, fallback, max) {
    const number = Number(value);
    return Number.isFinite(number) && number > 0 && number <= max ? number : fallback;
}

function getPackageSettings(data) {
    const source = data && typeof data === 'object' ? data : {};
    const input = source.packages && typeof source.packages === 'object' ? source.packages : {};
    const packages = {};
    PACKAGE_KEYS.forEach(key => {
        const fallback = DEFAULT_PACKAGES[key];
        const candidate = input[key] && typeof input[key] === 'object' ? input[key] : {};
        const label = typeof candidate.label === 'string' ? candidate.label.trim().slice(0, 40) : '';
        packages[key] = {
            label: label || fallback.label,
            length: positiveNumber(candidate.length, fallback.length, MAX_PACKAGE_DIMENSION_IN),
            width: positiveNumber(candidate.width, fallback.width, MAX_PACKAGE_DIMENSION_IN),
            height: positiveNumber(candidate.height, fallback.height, MAX_PACKAGE_DIMENSION_IN),
            weightOz: positiveNumber(candidate.weightOz, fallback.weightOz, MAX_WEIGHT_OZ)
        };
    });
    const defaultPackage = PACKAGE_KEYS.includes(source.defaultPackage)
        ? source.defaultPackage
        : 'small';
    const defaultItemWeightOz = positiveNumber(source.defaultItemWeightOz, 4, MAX_WEIGHT_OZ);
    return { packages, defaultPackage, defaultItemWeightOz };
}

async function readJson(response) {
    if (!response.ok) throw new Error('upstream request failed');
    return response.json();
}

module.exports = async (req, res) => {
    res.setHeader('Cache-Control', 'no-store');
    if (req.method !== 'POST') {
        return res.status(405).json({ error: 'method_not_allowed' });
    }

    const body = parseBody(req.body);
    if (!body || typeof body.zip !== 'string' || !/^\d{5}$/.test(body.zip) ||
        !Array.isArray(body.items) || body.items.length < 1 || body.items.length > 50 ||
        body.items.some(item => !item || !Number.isInteger(item.id) || item.id < 1 ||
            !Number.isInteger(item.quantity) || item.quantity < 1 || item.quantity > 100)) {
        return res.status(400).json({ error: 'invalid_request' });
    }

    const token = process.env.SHIPPO_API_TOKEN;
    let addressFrom;
    try {
        addressFrom = JSON.parse(process.env.SHIP_FROM_ADDRESS || '');
    } catch {
        addressFrom = null;
    }
    if (!token || !addressFrom || typeof addressFrom !== 'object' || Array.isArray(addressFrom)) {
        return res.status(502).json({ error: 'rates_unavailable' });
    }

    try {
        const ids = Array.from(new Set(body.items.map(item => item.id)));
        const headers = {
            apikey: SUPABASE_KEY,
            Authorization: `Bearer ${SUPABASE_KEY}`,
            Accept: 'application/json'
        };
        const productsUrl = `${SUPABASE_URL}/rest/v1/julis_products?select=id&id=in.(${ids.join(',')})`;
        const settingsUrl = `${SUPABASE_URL}/rest/v1/julis_settings?select=data&id=eq.1`;
        const [productRows, settingsRows] = await Promise.all([
            fetch(productsUrl, { headers }).then(readJson),
            fetch(settingsUrl, { headers }).then(readJson)
        ]);
        if (!Array.isArray(productRows) || !Array.isArray(settingsRows)) {
            throw new Error('invalid database response');
        }

        const productsById = new Map(productRows.map(product => [String(product.id), product]));
        if (ids.some(id => !productsById.has(String(id)))) {
            return res.status(400).json({ error: 'invalid_request' });
        }
        const packageSettings = getPackageSettings(settingsRows[0]?.data);
        const selectedPackage = packageSettings.packages[packageSettings.defaultPackage];
        const totalQuantity = body.items.reduce((sum, item) => sum + item.quantity, 0);
        const weightOz = Math.max(1, Math.round((
            selectedPackage.weightOz + packageSettings.defaultItemWeightOz * totalQuantity
        ) * 100) / 100);

        const shippoToken = token.trim();
        const shipmentResponse = await fetch('https://api.goshippo.com/shipments/', {
            method: 'POST',
            headers: {
                Authorization: `ShippoToken ${shippoToken}`,
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({
                address_from: addressFrom,
                address_to: { zip: body.zip, country: 'US' },
                parcels: [{
                    length: String(selectedPackage.length),
                    width: String(selectedPackage.width),
                    height: String(selectedPackage.height),
                    distance_unit: 'in',
                    weight: String(weightOz),
                    mass_unit: 'oz'
                }],
                async: false
            })
        });
        const shipment = await readJson(shipmentResponse);
        const rates = Array.isArray(shipment?.rates) ? shipment.rates
            .map(rate => {
                const provider = String(rate?.provider || '').toUpperCase();
                const amount = Number(rate?.amount);
                if (!['USPS', 'UPS'].includes(provider) || !rate.object_id ||
                    typeof rate.servicelevel?.name !== 'string' || !Number.isFinite(amount) || amount < 0) {
                    return null;
                }
                const estimatedDays = rate.estimated_days === null || rate.estimated_days === undefined
                    ? null
                    : Number(rate.estimated_days);
                return {
                    id: String(rate.object_id),
                    provider,
                    service: rate.servicelevel.name,
                    amount,
                    days: Number.isFinite(estimatedDays) ? estimatedDays : null
                };
            })
            .filter(Boolean)
            .sort((a, b) => a.amount - b.amount)
            .slice(0, 6)
            : [];
        if (!rates.length) return res.status(502).json({ error: 'rates_unavailable' });
        return res.status(200).json({
            rates,
            packageLabel: selectedPackage.label,
            weightOz
        });
    } catch {
        return res.status(502).json({ error: 'rates_unavailable' });
    }
};
