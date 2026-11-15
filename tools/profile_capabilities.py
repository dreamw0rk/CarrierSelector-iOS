"""Describe explicit carrier settings; never substitute another firmware's defaults."""
def merge_settings(base, override):
    result = dict(base)
    for key, value in override.items():
        result[key] = (merge_settings(result[key], value)
                       if isinstance(result.get(key), dict) and isinstance(value, dict) else value)
    return result


def extract_settings(data, boards):
    def get(*keys):
        value = data
        for key in keys:
            if not isinstance(value, dict):
                return None
            value = value.get(key)
        return value

    def boolean(*keys):
        value = get(*keys)
        return value if isinstance(value, bool) else None

    def text(*keys):
        value = get(*keys)
        return value if isinstance(value, str) else None

    apns = [a for a in data.get('apns', []) if isinstance(a, dict)]
    internet = [a.get('apn') for a in apns if isinstance(a.get('type-mask'), int)
                and a['type-mask'] & 1 and isinstance(a.get('apn'), str)]
    codecs = get('IMSConfig', 'Media', 'AudioCodecs')
    evs = (any(isinstance(c, dict) and c.get('EncodingName') == 'EVS' for c in codecs.values())
           if isinstance(codecs, dict) else None)
    registration = data.get('PhoneNumberRegistrationGatewayAddress')
    if isinstance(registration, str):
        registration = [registration]
    registration = [r for r in (registration or []) if isinstance(r, str)]
    masks = [data[k] for k in ('APNEditabilityTypemask', 'APNEditabilityTypemaskNew')
             if type(data.get(k)) is int]
    editable = any(m & 1 for m in masks) if masks else None
    wifi = boolean('EnableWiFiCallingWithoutEntitlement')
    if wifi is None:
        wifi = boolean('IMSConfig', 'EnableWiFiCallingWithoutEntitlement')
    entitlements = get('CarrierEntitlements', 'SupportedEntitlements')
    if isinstance(entitlements, int) and entitlements & 128:
        wifi = False
    roaming = boolean('TechSettings', 'WifiCallingAllowedInRoaming')
    if roaming is None:
        roaming = boolean('WifiCallingAllowedInRoaming')
    return dict(boards=boards, ims=boolean('SupportsImsCapability'),
                volte=boolean('IMSConfig', 'Voice', 'EnableVolteByDefault'),
                volteSwitch=boolean('ShowVolteSwitch'), wifiWithoutEntitlement=wifi,
                wifiRoaming=roaming, wifiPriority=text('TechSettings', 'iRatPolicies', 'PreferredTechnology'),
                wifiName=text('OverrideOperatorWiFiName'), evs=evs, fiveGSwitch=boolean('Show5GSwitch'),
                apn=sorted(set(internet)), apnEditable=editable,
                epdg=text('TechSettings', 'IKE', 'RemoteAddress'), registration=registration,
                conference=text('IMSConfig', 'ConferenceCalling', 'conferenceServer'),
                xcap=boolean('IMSConfig', 'XCAP', 'supported'))
