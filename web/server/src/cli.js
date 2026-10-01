import './suppress-warnings.js';
import readline from 'node:readline';

const { loadConfig } = await import('./config.js');
const { openDatabase, audit, backupIfDue } = await import('./db.js');
const { storePassword } = await import('./auth.js');
const { hashPassword } = await import('./security.js');
const { issueLicense, getPlans } = await import('./store.js');
const { dayKey } = await import('./time.js');

const USAGE = `MacClean server CLI

  node src/cli.js set-password               read a new admin password from stdin and store it in the DB
  node src/cli.js hash-password              read a password from stdin, print an ADMIN_PASSWORD_HASH value
  node src/cli.js issue-license --email a@b.com --plan lifetime [--devices 2] [--note "…"]
  node src/cli.js backup                     write today's DB backup now (DATA_DIR/backups)

DATA_DIR (default /var/lib/macclean) selects the database.`;

function parseFlags(args) {
  const flags = {};
  for (let i = 0; i < args.length; i++) {
    if (!args[i].startsWith('--')) continue;
    const name = args[i].slice(2);
    const next = args[i + 1];
    if (next === undefined || next.startsWith('--')) flags[name] = true;
    else { flags[name] = next; i++; }
  }
  return flags;
}

/** Reads one line; hides the echo when stdin is a terminal. Piped input (`echo pw | …`) works too. */
async function readSecret(prompt) {
  if (!process.stdin.isTTY) {
    const chunks = [];
    for await (const chunk of process.stdin) chunks.push(chunk);
    return Buffer.concat(chunks).toString('utf8').split(/\r?\n/)[0];
  }
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: true });
  process.stdout.write(prompt);
  rl._writeToOutput = () => {};
  const answer = await new Promise((resolve) => rl.question('', resolve));
  rl.close();
  process.stdout.write('\n');
  return answer;
}

const [command, ...rest] = process.argv.slice(2);
const flags = parseFlags(rest);
const config = loadConfig();

try {
  switch (command) {
    case 'set-password': {
      const password = await readSecret('New admin password: ');
      const db = openDatabase(config.dbPath);
      await storePassword({ db, config }, password);
      db.prepare('DELETE FROM sessions').run();
      audit(db, 'admin.password_set_cli');
      db.close();
      console.log('Admin password updated; existing sessions were signed out.');
      if (config.adminPasswordHash) console.log('Note: ADMIN_PASSWORD_HASH is set in the environment and takes precedence over the DB password.');
      break;
    }
    case 'hash-password': {
      const password = await readSecret('Password to hash: ');
      if (!password || password.length < 10) throw new Error('Password must be at least 10 characters');
      console.log(await hashPassword(password));
      break;
    }
    case 'issue-license': {
      const db = openDatabase(config.dbPath);
      if (!flags.plan) throw new Error(`--plan is required (one of: ${getPlans(db).map((p) => p.id).join(', ')})`);
      const lic = issueLicense(db, {
        email: flags.email === true ? '' : flags.email, plan: flags.plan,
        devices: flags.devices === undefined ? undefined : Number(flags.devices), note: flags.note === true ? '' : flags.note,
      });
      audit(db, 'license.issue_cli', { target: lic.key, detail: { email: lic.email, plan: lic.plan_id, devices: lic.activation_limit } });
      db.close();
      console.log(lic.key);
      break;
    }
    case 'backup': {
      const db = openDatabase(config.dbPath);
      const written = backupIfDue(db, config.backupsDir, dayKey(new Date(), config.timeZone), config.backupKeep);
      db.close();
      console.log(written ? `Backup written: ${written}` : 'Today\'s backup already exists.');
      break;
    }
    default:
      console.log(USAGE);
      process.exitCode = command && command !== 'help' ? 1 : 0;
  }
} catch (err) {
  console.error(`Error: ${err.message}`);
  process.exitCode = 1;
}
