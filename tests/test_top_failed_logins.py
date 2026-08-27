import io
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

from src.top_failed_logins import count_failed_logins, run, top_users


class FailedLoginTests(unittest.TestCase):
    def test_counts_both_assignment_formats_and_ignores_successes(self):
        lines = [
            "INFO Failed login. Username=[alice]\n",
            "WARN failed   login Username[alice]\n",
            "INFO Failed login Username=[bob]\n",
            "INFO Successful login Username=[carol]\n",
        ]
        counts, malformed = count_failed_logins(lines)
        self.assertEqual(counts, {"alice": 2, "bob": 1})
        self.assertEqual(malformed, 0)

    def test_malformed_failed_login_is_reported(self):
        counts, malformed = count_failed_logins(["WARN Failed login: no user field\n"])
        self.assertFalse(counts)
        self.assertEqual(malformed, 1)

    def test_ties_are_deterministic(self):
        counts, _ = count_failed_logins(
            ["Failed login Username=[zoe]\n", "Failed login Username=[amy]\n"]
        )
        self.assertEqual(top_users(counts, 2), [("amy", 1), ("zoe", 1)])

    def test_cli_limits_output(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "app.log"
            path.write_text(
                "Failed login Username=[alice]\n"
                "Failed login Username=[alice]\n"
                "Failed login Username=[bob]\n",
                encoding="utf-8",
            )
            stdout = io.StringIO()
            with redirect_stdout(stdout):
                result = run([str(path), "--limit", "1"])
            self.assertEqual(result, 0)
            self.assertEqual(stdout.getvalue(), "2 alice\n")

    def test_missing_file_returns_failure(self):
        stderr = io.StringIO()
        self.assertEqual(run(["does-not-exist.log"], stderr=stderr), 2)
        self.assertIn("cannot read", stderr.getvalue())


if __name__ == "__main__":
    unittest.main()
