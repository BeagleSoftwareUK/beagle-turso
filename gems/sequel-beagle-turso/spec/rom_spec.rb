require "rom"
require "rom-sql"
require "rom-repository"

RSpec.describe "ROM on sequel-beagle-turso" do
  author_repo = Class.new(ROM::Repository[:authors]) do
    commands :create, update: :by_pk

    def by_id(id) = authors.by_pk(id).one

    def with_posts(id) = authors.combine(:posts).by_pk(id).one
  end

  it "infers relations, runs a repository's CRUD, an association and a migration" do
    path = tmp_db
    gateway_db = Sequel.connect("beagle-turso://#{path}")
    # ROM::SQL.migration needs a current gateway, which only exists while
    # migration files load; outside that, the DSL hangs off a gateway.
    migration = ROM::SQL::Gateway.new(gateway_db).migration do
      change do
        create_table(:authors) { primary_key :id; String :name, null: false }
        create_table(:posts) do
          primary_key :id
          foreign_key :author_id, :authors, null: false
          String :title
          TrueClass :published, default: false
          Date :on
        end
      end
    end
    migration.apply(gateway_db, :up)

    config = ROM::Configuration.new(:sql, gateway_db)
    config.relation(:authors) do
      schema(infer: true) { associations { has_many :posts } }
    end
    config.relation(:posts) do
      schema(infer: true) { associations { belongs_to :author } }
    end
    rom = ROM.container(config)

    authors = rom.relations[:authors]
    posts = rom.relations[:posts]
    a = authors.command(:create).call(name: "Ada")
    posts.command(:create).call(author_id: a[:id], title: "Hello", published: true, on: Date.new(2026, 10, 17))

    row = posts.where(author_id: a[:id]).one
    expect(row[:published]).to be(true)
    expect(row[:on]).to eq(Date.new(2026, 10, 17))

    with_posts = authors.combine(:posts).where(id: a[:id]).one
    expect(with_posts[:posts].map { _1[:title] }).to eq(["Hello"])

    authors.by_pk(a[:id]).command(:update).call(name: "Ada L.")
    expect(authors.by_pk(a[:id]).one[:name]).to eq("Ada L.")
    posts.where(author_id: a[:id]).command(:delete).call
    expect(posts.count).to eq(0)

    repo = author_repo.new(rom)
    grace = repo.create(name: "Grace")
    expect(grace.name).to eq("Grace")
    expect(repo.by_id(grace.id).name).to eq("Grace")
    repo.update(grace.id, name: "Grace H.")
    expect(repo.by_id(grace.id).name).to eq("Grace H.")
    posts.command(:create).call(author_id: grace.id, title: "COBOL", published: false)
    aggregate = repo.with_posts(grace.id)
    expect(aggregate.name).to eq("Grace H.")
    expect(aggregate.posts.map(&:title)).to eq(["COBOL"])
    expect(aggregate.posts.first.published).to be(false)
  ensure
    rom&.disconnect
    gateway_db&.close_replica
  end
end
