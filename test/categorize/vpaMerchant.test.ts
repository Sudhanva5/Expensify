import { describe, it, expect } from 'vitest';
import {
  decodeVpaMerchant,
  isMerchantRawAnEchoOfVpa,
} from '../../src/categorize/vpaMerchant.js';

// Every VPA in this file is a real row pulled from the production DB.
// If a case here looks arbitrary, it isn't — it's a shape HDFC actually sent.

describe('decodeVpaMerchant — gateway extraction', () => {
  const cases: Array<[string, string]> = [
    ['netflixupi.payu@hdfcbank', 'PayU'],
    ['airtel4.payu@icici', 'PayU'],
    ['makemytrip.payu@axisbank', 'PayU'],
    ['snitchapparelsp711507.rzp@rxaxis', 'Razorpay'],
    ['airbnbpaymentsind1.rzp@hdfcbank', 'Razorpay'],
    ['openaillc.cfp@cashfreensdlpb', 'Cashfree'],
    ['ctrlxtechnologiesp9.cf@axisbank', 'Cashfree'],
    ['justswish.hyperpg@axb', 'Juspay'],
    ['lic.billdesk@hdfcbank', 'BillDesk'],
    ['paytm.d15687920262@pty', 'Paytm'],
    ['paytm-74641194@ptys', 'Paytm'],
    ['paytm-950206@ptybl', 'Paytm'],
    ['0790422a0069078.bqr@kotak', 'BharatQR'],
    ['redbus.dbqr.payu@indus', 'PayU'],
  ];

  for (const [vpa, gateway] of cases) {
    it(`reads ${gateway} out of ${vpa}`, () => {
      expect(decodeVpaMerchant(vpa)?.gateway).toBe(gateway);
    });
  }
});

describe('decodeVpaMerchant — merchant extraction', () => {
  const cases: Array<[string, string]> = [
    ['netflixupi.payu@hdfcbank', 'Netflix'],
    ['zepto.payu@axisbank', 'Zepto'],
    ['swish-12618744.payu@indus', 'Swish'],
    // Both of District's product-line VPAs collapse to the one brand.
    ['districtmovies.payu@hdfcbank', 'District'],
    ['districtmovieticket.payu@hdfcbank', 'District'],
    ['redbus32.rzp@hdfcbank', 'redBus'],
    ['makemytrip.payu@axisbank', 'MakeMyTrip'],
    ['healthifyme.payu@indus', 'Healthifyme'],
    // QR-rail markers are dropped without being mistaken for the aggregator:
    // the gateway here is PayU, not the "dbqr" segment.
    ['redbus.dbqr.payu@indus', 'redBus'],
    // Corporate-suffix stripping.
    ['munchmarttechnologies.payu@mairtel', 'Munchmart'],
    ['zeptomarketplaceprivat39.rzp@hdfcbank', 'Zepto'],
    // Trailing single-char remnant only dropped when doing so unlocks a
    // real suffix match: snitchapparelsp -> snitchapparels -> snitch.
    ['snitchapparelsp711507.rzp@rxaxis', 'Snitch'],
    ['ctrlxtechnologiesp9.cf@axisbank', 'Ctrlx'],
    // Multi-hop: airbnbpaymentsind -> airbnbpayments -> airbnb.
    ['airbnbpaymentsind1.rzp@hdfcbank', 'Airbnb'],
    // Canonical-casing overrides for names title-case would mangle.
    ['openaillc.cfp@cashfreensdlpb', 'OpenAI'],
    ['lic.billdesk@hdfcbank', 'LIC'],
  ];

  for (const [vpa, merchant] of cases) {
    it(`reads ${merchant} out of ${vpa}`, () => {
      expect(decodeVpaMerchant(vpa)?.merchant).toBe(merchant);
    });
  }
});

describe('decodeVpaMerchant — refuses to guess', () => {
  it('returns a gateway but NO merchant for opaque Paytm merchant ids', () => {
    const out = decodeVpaMerchant('paytm.d15687920262@pty');
    expect(out?.gateway).toBe('Paytm');
    expect(out?.merchant).toBeNull();
  });

  it('returns a gateway but NO merchant for opaque Paytm dash ids', () => {
    const out = decodeVpaMerchant('paytm-80132274@ptys');
    expect(out?.gateway).toBe('Paytm');
    expect(out?.merchant).toBeNull();
  });

  it('returns a gateway but NO merchant for a hex BharatQR blob', () => {
    const out = decodeVpaMerchant('0790422a0069078.bqr@kotak');
    expect(out?.gateway).toBe('BharatQR');
    expect(out?.merchant).toBeNull();
  });

  it('returns null for an opaque PhonePe merchant id with no gateway token', () => {
    expect(decodeVpaMerchant('q385969427@ybl')).toBeNull();
  });

  it('returns null for a plain merchant VPA carrying no gateway token', () => {
    expect(decodeVpaMerchant('UNIQLOPPDQR22@ybl')).toBeNull();
  });

  it('returns null for malformed input', () => {
    expect(decodeVpaMerchant('')).toBeNull();
    expect(decodeVpaMerchant('no-at-sign')).toBeNull();
    expect(decodeVpaMerchant('@ybl')).toBeNull();
  });
});

describe('decodeVpaMerchant — personal-VPA guard', () => {
  // Renaming a human being after a payment-gateway heuristic is the one
  // unacceptable failure mode here. Personal VPAs must decode to nothing,
  // even when their local part happens to contain a gateway-ish token.
  const personal = [
    'sneha.r@oksbi',
    'ambuja.acharya5@oksbi',
    'abdulhanif78999@oksbi',
    '9886739677-3@ybl',
    '7759973543-3@ybl',
    '8962299257@pthdfc',
    'chauhankareena614@okicici',
  ];

  for (const vpa of personal) {
    it(`refuses to decode ${vpa}`, () => {
      expect(decodeVpaMerchant(vpa)).toBeNull();
    });
  }
});

describe('isMerchantRawAnEchoOfVpa', () => {
  // The decoded name is only allowed to win when the bank gave us nothing
  // but a copy of the VPA. When HDFC sent a real trading name, that wins.
  it('detects merchantRaw that is a verbatim copy of the VPA local part', () => {
    expect(
      isMerchantRawAnEchoOfVpa('districtmovies.payu', 'districtmovies.payu@hdfcbank'),
    ).toBe(true);
    expect(
      isMerchantRawAnEchoOfVpa('snitchapparelsp711507.rzp', 'snitchapparelsp711507.rzp@rxaxis'),
    ).toBe(true);
    expect(
      isMerchantRawAnEchoOfVpa('paytm.d15687920262', 'paytm.d15687920262@pty'),
    ).toBe(true);
  });

  it('detects a copy of the whole VPA including handle', () => {
    expect(
      isMerchantRawAnEchoOfVpa('zepto.payu@axisbank', 'zepto.payu@axisbank'),
    ).toBe(true);
  });

  it('ignores case and separator noise', () => {
    expect(
      isMerchantRawAnEchoOfVpa('SWISH-12618744.PAYU', 'swish-12618744.payu@indus'),
    ).toBe(true);
  });

  it('leaves a real bank-supplied trading name alone', () => {
    expect(isMerchantRawAnEchoOfVpa('NETFLIX COM', 'netflixupi.payu@hdfcbank')).toBe(false);
    expect(isMerchantRawAnEchoOfVpa('Airtel', 'airtel4.payu@icici')).toBe(false);
    expect(
      isMerchantRawAnEchoOfVpa(
        'MUNCHMART TECHNOLOGIES PRIVATE LIMITED',
        'justswish.hyperpg@axb',
      ),
    ).toBe(false);
    expect(isMerchantRawAnEchoOfVpa('Tacobell Nexus Mall', 'paytm-74641194@ptys')).toBe(false);
  });
});
