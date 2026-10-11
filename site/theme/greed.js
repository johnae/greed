// The book's title in the top bar goes back to greed.rs's front page.
for (const title of document.querySelectorAll(".menu-title")) {
  const link = document.createElement("a");
  link.href = "/";
  link.textContent = title.textContent;
  link.className = "home";
  title.replaceChildren(link);
}
