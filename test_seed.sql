CREATE TABLE roles (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL
);

CREATE TABLE users (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  email TEXT NOT NULL,
  role_id INTEGER REFERENCES roles(id)
);

CREATE TABLE posts (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  body TEXT,
  author_id INTEGER NOT NULL REFERENCES users(id)
);

INSERT INTO roles (name) VALUES ('admin'), ('editor'), ('viewer');
INSERT INTO users (name, email, role_id) VALUES
  ('Alice', 'alice@example.com', 1),
  ('Bob',   'bob@example.com',   2),
  ('Carol', 'carol@example.com', 3);
INSERT INTO posts (title, body, author_id) VALUES
  ('Hello World', 'First post body', 1),
  ('Second Post', NULL, 2);
