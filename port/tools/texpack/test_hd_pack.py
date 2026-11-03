import argparse
import contextlib
import io
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch

import hd_pack


class PackSafetyTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.row = [1, 4, 4, 0, 0, 0, 0, 0]

    def texture(self, id_=1, truncated=False):
        p = self.root / 'game/hd/Textures' / str(id_)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(struct.pack('<IIIiii', 0x504d4d, 6, 0, 8, 8, 1) + bytes(255 if truncated else 256))
        return p

    def args(self):
        man = self.root / 'manifest.tsv'
        man.write_text('1 1 4 4 0 0 0 0 0\n')
        return argparse.Namespace(manifest=str(man), game=str(self.root / 'game'), work=str(self.root / 'work'),
                                  cap=2048, quarantine=False, audit=False, texpack='texpack', upscaler='upscaler',
                                  model='model', models='models', timeout=5, batch=1)

    def test_font_atlas_never_eligible(self):
        r = self.row[:]; r[-1] = 1
        self.assertFalse(hd_pack.eligible(r))

    def test_size_cap_is_terminal(self):
        r = self.row[:]; r[1] = 2048
        self.assertFalse(hd_pack.eligible(r))

    def test_truncated_mip_rejected(self):
        self.assertEqual(hd_pack.validate(self.texture(truncated=True), self.row), 'truncated or excess mip payload')

    def test_old_manifest_rejected(self):
        p = self.root / 'old.tsv'; p.write_text('1 1 4 4 0 0 0 0\n')
        with self.assertRaises(ValueError):
            hd_pack.manifest(p)

    def test_complete_pack_skips_upscaler(self):
        args = self.args(); self.texture()
        with patch('hd_pack.subprocess.check_output', return_value='1\n'), patch('hd_pack.subprocess.run') as run:
            with contextlib.redirect_stdout(io.StringIO()): self.assertEqual(hd_pack.run(args), 0)
            run.assert_not_called()

    def test_missing_source_is_reported_without_retry(self):
        args = self.args()
        with patch('hd_pack.subprocess.check_output', return_value=''), patch('hd_pack.subprocess.run') as run:
            with contextlib.redirect_stdout(io.StringIO()): self.assertEqual(hd_pack.run(args), 0)
            run.assert_not_called()
        self.assertIn('"unavailable_source": [\n    1', (Path(args.work) / 'report.json').read_text())

    def test_silent_encoder_failure_has_two_attempts(self):
        args = self.args()
        def fake_run(cmd, **kwargs):
            if cmd[1] == 'extract':
                (Path(cmd[-1]) / '1.png').write_bytes(b'original')
            return argparse.Namespace(returncode=0)
        with patch('hd_pack.subprocess.check_output', return_value='1\n'), patch('hd_pack.subprocess.run', side_effect=fake_run) as run:
            with contextlib.redirect_stdout(io.StringIO()): self.assertEqual(hd_pack.run(args), 1)
            self.assertEqual(sum(c.args[0][0] == 'upscaler' for c in run.call_args_list), 2)
        self.assertEqual((Path(args.work) / 'png/1.png').read_bytes(), b'original')

    def table(self, *rows):
        names = 'id format w h hdw hdh src_mean hd_mean rgb_err alpha_err hidden_frac hidden_src hidden_hd alpha_frac mip_src mip_hd'
        p = self.root / 'pixels.tsv'
        p.write_text('\n'.join([names, *rows]) + '\n')
        return p

    def test_blackened_texture_fails_pixel_gate(self):
        p = self.table('4915 6 128 128 256 256 6.68 0.00 6.68 0 0.2392 26.62 0 1 -1 -1')
        self.assertIn('4915', hd_pack.pixel_failures(p))

    def test_hidden_colour_loss_fails_even_when_mean_is_dark(self):
        p = self.table('7 6 64 64 128 128 2.00 1.90 0.5 0 0.1000 26.00 3.00 1 -1 -1')
        self.assertIn('7', hd_pack.pixel_failures(p))

    def test_distant_brightening_fails_pixel_gate(self):
        p = self.table('9 1 128 128 256 256 100 100 1 0 0 0 0 0 80 120')
        self.assertIn('9', hd_pack.pixel_failures(p))

    def test_faithful_texture_passes_pixel_gate(self):
        p = self.table('11 1 128 128 256 256 100 99 2 0 0 0 0 0 80 81')
        self.assertEqual(hd_pack.pixel_failures(p), {})

    def test_bad_atlas_quarantined_without_deletion(self):
        args = self.args(); args.audit = True; args.quarantine = True
        p = self.texture(); original = p.read_bytes()
        Path(args.manifest).write_text('1 0 4 4 0 0 0 0 1\n')
        with patch('hd_pack.subprocess.check_output', return_value='1\n'):
            with contextlib.redirect_stdout(io.StringIO()): self.assertEqual(hd_pack.run(args), 0)
        self.assertFalse(p.exists())
        self.assertEqual((Path(args.work) / 'quarantine/1').read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
