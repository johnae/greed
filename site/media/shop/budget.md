# Shop budget

Monthly rent [900](field:rent) €, and we're [3](field:people) people.

<!-- let per_person = rent / people -->
Each pays {{ fixed(per_person) }} € in rent.

<!-- id=costs -->
| Item     | Amount | Per year | So far |
|----------|-------:|---------:|-------:|
| Rent     | 900    |          |        |
| Hosting  | 120    |          |        |
| Coffee   | 85     |          |        |
| Licenses | 240    |          |        |
<!-- formula: per_year = amount * 12 -->
<!-- formula: so_far = (if prev then prev.so_far else 0) + amount -->
<!-- chart: bar per_year -->

{{ count(costs.item) }} costs, {{ sum(costs.per_year) }} € a year.
