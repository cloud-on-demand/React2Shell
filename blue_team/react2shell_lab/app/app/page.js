export const runtime = "nodejs";

async function checkIn() {
  "use server";
  console.info("React2Shell lab check-in");
}

export default function Home() {
  return (
    <main className="lab">
      <p className="lab-label">Blue Team · Challenge Host</p>
      <h1>React2Shell Lab</h1>
      <p className="lab-intro">A React Server Components lab for the Blue Team walkthrough.</p>

      <section className="check-in" aria-labelledby="check-in-title">
        <div>
          <h2 id="check-in-title">Server check-in</h2>
          <p id="check-in-description">Record a check-in in the server log.</p>
        </div>
        <form action={checkIn}>
          <button type="submit" aria-describedby="check-in-description">Check in</button>
        </form>
      </section>
    </main>
  );
}
