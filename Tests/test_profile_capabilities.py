import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from profile_capabilities import extract_settings, merge_settings


class CapabilitiesTests(unittest.TestCase):
    def test_missing_is_unknown(self):
        result = extract_settings({}, [])
        for key in ('volte', 'ims', 'evs', 'fiveGSwitch', 'wifiWithoutEntitlement', 'apnEditable'):
            self.assertIsNone(result[key])

    def test_board_override_preserves_siblings_and_replaces_arrays(self):
        base = {'IMSConfig': {'Voice': {'EnableVolteByDefault': True}, 'Media': {'AudioCodecs': {'1': {'EncodingName': 'EVS'}}}}, 'apns': [{'apn': 'old'}]}
        merged = merge_settings(base, {'IMSConfig': {'Voice': {'EnableVolteByDefault': False}}, 'apns': [{'apn': 'new', 'type-mask': 1}]})
        result = extract_settings(merged, ['D83'])
        self.assertFalse(result['volte'])
        self.assertTrue(result['evs'])
        self.assertEqual(result['apn'], ['new'])
        self.assertTrue(base['IMSConfig']['Voice']['EnableVolteByDefault'])

    def test_explicit_false_is_not_missing(self):
        result = extract_settings({'EnableWiFiCallingWithoutEntitlement': False, 'IMSConfig': {'EnableWiFiCallingWithoutEntitlement': True}, 'Show5GSwitch': False}, [])
        self.assertFalse(result['wifiWithoutEntitlement'])
        self.assertFalse(result['fiveGSwitch'])

    def test_entitlement_overrides_no_entitlement_flag(self):
        result = extract_settings({'EnableWiFiCallingWithoutEntitlement': True, 'CarrierEntitlements': {'SupportedEntitlements': 128}}, [])
        self.assertFalse(result['wifiWithoutEntitlement'])

    def test_apn_masks_and_registration_variants(self):
        result = extract_settings({'APNEditabilityTypemask': 0, 'APNEditabilityTypemaskNew': 53, 'PhoneNumberRegistrationGatewayAddress': '13191'}, [])
        self.assertTrue(result['apnEditable'])
        self.assertEqual(result['registration'], ['13191'])


if __name__ == '__main__':
    unittest.main()
