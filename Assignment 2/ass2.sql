-- COMP9311 Assignment 2
-- Written by Chencheng Xie, 18 Jul 2019

-- Q1: get details of the current Heads of Schools

create or replace view Q1(name, school, starting)
as
	select p.name, o.longname, a.starting
	from People p
	join Staff s on (p.id = s.id)
	join Affiliation a on (a.staff = s.id)
	join OrgUnits o on (a.orgunit = o.id)
	join OrgUnitTypes ot on (o.utype = ot.id)
	join StaffRoles sr on (a.role = sr.id)
	where ot.name = 'School' and sr.description = 'Head of School' and a.ending is null and a.isprimary = 't'
;

-- Q2: longest-serving and most-recent current Heads of Schools

create or replace view Q2(status, name, school, starting)
as
	select 'Longest serving', name, school, starting
	from Q1
	where starting = (select min(starting) from Q1)
	union
	select 'Most recent', name, school, starting
	from Q1
	where starting = (select max(starting) from Q1)
;

-- Q3: term names

create or replace function
	Q3(integer) returns text
as
$$
	select SUBSTR(year::text,3,2)||lower(sess)
	from Terms
	where Terms.id = $1
$$ language sql;


-- Q4: percentage of international students, S1 and S2, 2005..2011

create or replace view Q4_sub(term, type)
as
	select SUBSTR(t.year::text,3,2)||lower(t.sess), s.stype
	from Terms t
	join ProgramEnrolments pe on (t.id = pe.term)
	join Students s on (s.id = pe.student)
	where t.year >= 2005 and t.sess LIKE 'S%'
;

create or replace view Q4_total(term, count)
as
	select term, count(type)
	from Q4_sub
	group by term
;

create or replace view Q4_intl(term, count)
as
	select term, count(type)
	from Q4_sub
	where type = 'intl'
	group by term
;

create or replace view Q4(term, percent)
as
	select t.term, (i.count/(t.count::float))::numeric(4,2)
	from Q4_total t
	join Q4_intl i on (t.term = i.term)
	order by t.term
;

-- Q5: total FTE students per term since 2005

create or replace view Q5_sub(term, student, uoc)
as
	select SUBSTR(t.year::text,3,2)||lower(t.sess), ce.student, s.uoc
	from Courses c
	join CourseEnrolments ce on (c.id = ce.course)
	join Terms t on (c.term = t.id)
	join Subjects s on (c.subject = s.id)
	where t.year >= 2000 and t.year < 2011 and t.sess like 'S%'
;

create or replace view Q5(term, nstudes, fte)
as
	select term, count(distinct student), (sum(uoc)/(24::float))::numeric(6,1)
	from Q5_sub
	group by term
;

-- Q6: subjects with > 30 course offerings and no staff recorded

create or replace view Q6_subject(subject)
as
	(select c2.subject
	from Courses c2)
	except
	(select c.subject
	from coursestaff cs
	join courses c on (cs.course = c.id))
;

create or replace view Q6_sub(subject, nOfferings)
as
	select s.code||' '||s.name, count(c.id)
	from Q6_subject q
	join subjects s on (q.subject = s.id)
	join courses c on (q.subject = c.subject)
	group by s.code, s.name
;

create or replace view Q6(subject, nOfferings)
as
	select subject, nOfferings
	from Q6_sub
	where nOfferings > 30
;

-- Q7:  which rooms have a given facility

create or replace function
	Q7(text) returns setof FacilityRecord
as $$
	select r.longname, f.description
	from Rooms r
	join Roomfacilities rf on (r.id = rf.room)
	join Facilities f on (rf.facility = f.id)
	where (select regexp_matches(lower(f.description), lower($1)) is not null)
$$ language sql
;

-- Q8: semester containing a particular day

create or replace function Q8(_day date) returns text
as $$
declare
	r RECORD;
	i integer := 0;
	last_end date;
begin
	FOR r IN select * from terms order by starting
	LOOP
		IF (r.starting <= _day and r.ending >= _day) THEN
			i := r.id;
			RETURN Q3(i);
		ELSEIF (last_end < _day AND _day < r.starting) THEN
			IF (last_end < r.starting - '1 week'::interval) THEN
				IF (_day >= r.starting - '1 week'::interval) THEN
					i := r.id;
					RETURN Q3(i);
				ELSE
					RETURN Q3(i);
				END IF;
			ELSE
				RETURN Q3(i);
			END IF;
		ELSEIF (r.ending < _day) THEN
			last_end := r.ending;
			i := r.id;
		END IF;
	END LOOP;
	RETURN Q3(0);
end;
$$ language plpgsql
;

-- Q9: transcript with variations

create type VariationsRecord as (
	student		integer,
	subject		integer,
	vtype		variationtype,
	intequiv	integer,
	extequiv	integer,
	code		character(8),
	uoc			integer,
	intCode		character(8),
	institution	longname
);

create or replace function
	Q9(_sid integer) returns setof TranscriptRecord
as $$
declare
	rec TranscriptRecord;
	var VariationsRecord;
	UOCtotal integer := 0;
	UOCpassed integer := 0;
	extraUOC integer := 0;
	wsum integer := 0;
	wam integer := 0;
	x integer;
begin
	select s.id into x
	from   Students s join People p on (s.id = p.id)
	where  p.unswid = _sid;
	if (not found) then
		raise EXCEPTION 'Invalid student %',_sid;
	end if;
	for rec in
		select su.code, substr(t.year::text,3,2)||lower(t.sess),
			su.name, e.mark, e.grade, su.uoc
		from CourseEnrolments e join Students s on (e.student = s.id)
			join People p on (s.id = p.id)
			join Courses c on (e.course = c.id)
			join Subjects su on (c.subject = su.id)
			join Terms t on (c.term = t.id)
		where p.unswid = _sid
		order by t.starting,su.code
	loop
		if (rec.grade = 'SY') then
			UOCpassed := UOCpassed + rec.uoc;
		elsif (rec.mark is not null) then
			if (rec.grade in ('PT','PC','PS','CR','DN','HD')) then
				-- only counts towards creditted UOC
				-- if they passed the course
				UOCpassed := UOCpassed + rec.uoc;
			end if;
			-- we count fails towards the WAM calculation
			UOCtotal := UOCtotal + rec.uoc;
			-- weighted sum based on mark and uoc for course
			wsum := wsum + (rec.mark * rec.uoc);
		end if;
		return next rec;
	end loop;
	for var in
		select v.student, v.subject, v.vtype, v.intequiv, v.extequiv,
			s.code, s.uoc, ss.code as intCode, es.institution
			from Variations v
				join Subjects s on (v.subject = s.id)
				left join Subjects ss on (v.intequiv = ss.id)
				left join ExternalSubjects es on (v.extequiv = es.id)
			where v.student = x
	loop
		if (var.vtype = 'advstanding') then
			rec := (var.code,null,'Advanced standing, based on ...',null,null, var.uoc);
			extraUOC := extraUOC + var.uoc;
		elsif (var.vtype = 'substitution') then
			rec := (var.code,null,'Substitution, based on ...',null,null, null);
		else
			rec := (var.code,null,'Exemption, based on ...',null,null, null);
		end if;
		return next rec;
		if (var.intequiv is not null) then
			rec := (null, null, 'studying '||var.intCode||' at UNSW', null, null, null);
		else
			rec := (null, null, 'study at '||var.institution, null, null, null);
		end if;
		return next rec;
	end loop;
	if (UOCtotal = 0) then
		rec := (null,null,'No WAM available',null,null,null);
	else
		wam := wsum / UOCtotal;
		rec := (null,null,'Overall WAM',wam,null,UOCpassed+extraUOC);
	end if;
	-- append the last record containing the WAM
	return next rec;
	return;
end;
$$ language plpgsql
;
