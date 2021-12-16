#version 450

layout (local_size_x = 1, local_size_x = 1) in;
layout (binding=0, rgba8) uniform image2D output_texture;
layout (binding=1, rgba32f) uniform image2D debug_texture;


// *****************************************************************************
// *                              Constants                                    *
// *****************************************************************************
#define PI 					  3.1415926
#define TWO_PI 				6.2831852
#define FOUR_PI 			12.566370
#define INV_PI 				0.3183099
#define INV_TWO_PI 		0.1591549
#define INV_FOUR_PI 	0.0795775
#define EPSILON       1e-8


// *****************************************************************************
// *                                Utils                                      *
// *****************************************************************************

// By Moroz Mykhailo (https://www.shadertoy.com/view/wltcRS)
uvec4 seed;
ivec2 pixel;

void InitRNG(vec2 p, int frame)
{
    pixel = ivec2(p);
    seed = uvec4(p, uint(frame), uint(p.x) + uint(p.y));
}

void pcg4d(inout uvec4 v)
{
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.w; v.y += v.z * v.x; v.z += v.x * v.y; v.w += v.y * v.z;
    v = v ^ (v >> 16u);
    v.x += v.y * v.w; v.y += v.z * v.x; v.z += v.x * v.y; v.w += v.y * v.z;
}

float rand()
{
    pcg4d(seed); return float(seed.x) / float(0xffffffffu);
}

float distribGGX(float dotNH, float alpha2)
{
  float dotNH2 = pow(dotNH, 2.0);
  float bot = dotNH2 * (alpha2 - 1.0) + 1.0;
  return alpha2 / (PI * bot * bot);
}

// *****************************************************************************
// *                                Structs                                    *
// *****************************************************************************

struct Ray
{
  vec3 origin;
  vec3 dir;
};

struct Light
{
  vec3 position;
};

struct Material
{
  vec3 diffusivity;
  vec3 emission;
};


struct Sphere
{
  vec3 center;
  float radius;
  Material mat;
};

struct Triangle
{
  vec3 p0;
  vec3 p1;
  vec3 p2;
  Material mat;
};

struct Collision
{
  float t;              // distance along ray
  vec3 p;               // world position of collision
  vec3 n;               // surface normal at collision
  bool inside;          // ray inside the object or not
  Material mat;
  Ray ray;
  int object_index;     // index of the object
};

struct Sample
{
  vec3 value;
  float pdf;
};


// *****************************************************************************
// *                                 Scene                                     *
// *****************************************************************************

Light light = Light(vec3(0, 1, 3));

Material emissive = Material(
  vec3(1, 1, 1),
  vec3(1, 1, 1)
);

Material gray = Material(
  vec3(0.2, 0.2, 0.2),
  vec3(0, 0, 0)
);

Material red = Material(
  vec3(1, 1, 1),
  vec3(0, 0, 0)
);

Material blue = Material(
  vec3(0, 0, 1),
  vec3(0, 0, 0)
);

Sphere sphere = Sphere(vec3(-1.5, -1.5, -2.5), 1.5, blue);
Sphere sphere2 = Sphere(vec3(1.5, -1.5, -2.5), 1.5, red);

Triangle triangle0 = Triangle(
  vec3(5, -3, -5),
  vec3(-5, -3, -5),
  vec3(5, -3, 0),
  gray
);

Triangle triangle1 = Triangle(
  vec3(-5, -3, 0),
  vec3(5, -3, 0),
  vec3(-5, -3, -5),
  gray
);

Triangle triangle2 = Triangle(
  vec3(-10, 4, -10),
  vec3(10, 4, -10),
  vec3(0, 0, 10),
  emissive
);

//Triangle triangle2 = Triangle(
//  vec3(5, 2, -5),
//  vec3(5, 2, 0),
//  vec3(-5, 2, -5),
//  emissive
//);

Triangle triangle3 = Triangle(
  vec3(-5, 2, 0),
  vec3(-5, 2, -5),
  vec3(5, 2, 0),
  emissive
);

float camera_pos_z = 3.0;


Collision collisions[5];

vec3 ambient = vec3(0.05, 0.05, 0.05);


// *****************************************************************************
// *                              Functions                                    *
// *****************************************************************************


// UTILS

vec3 local_to_world(vec3 local_dir, vec3 normal)
{
  vec3 binormal = normalize(
    (abs(normal.x) > abs(normal.y))
      ? vec3(normal.z, 0.0, -normal.x)
      : vec3(0.0, -normal.z, normal.y) 
  );

	vec3 tangent = cross(binormal, normal);
    
	return local_dir.x*tangent + local_dir.y*binormal + local_dir.z*normal;
}

void cartesian_to_spherical(in vec3 xyz, out float rho, out float phi, out float theta)
{
  rho = sqrt((xyz.x * xyz.x) + (xyz.y * xyz.y) + (xyz.z * xyz.z));
  phi = asin(xyz.y / rho);
	theta = atan( xyz.z, xyz.x );
}

vec3 spherical_to_cartesian(float rho, float phi, float theta)
{
  float sinTheta = sin(theta);
  return vec3(sinTheta*cos(phi), sinTheta*sin(phi), cos(theta)) * rho;
}


// Collisions

// Adapted from scratchapixel's sphere collision 
Collision collision(Sphere sphere, Ray ray)
{
  Collision obj_col;
  obj_col.inside = false;

  vec3 oc = sphere.center - ray.origin;
  float t_ca = dot(oc, ray.dir);
  float d2 = dot(oc, oc) - t_ca * t_ca;

  // Ray goes outside of sphere
  if (d2 > sphere.radius * sphere.radius) 
  {
    obj_col.t = -1;
    return obj_col;
  }

  float t_hc = sqrt(sphere.radius*sphere.radius - d2);
  float t0 = t_ca - t_hc;
  float t1 = t_ca + t_hc;
  float t_near = min(t0, t1);
  float t_far = max(t0, t1);
  obj_col.t = t_near;

  // Sphere behind the ray, no collision
  if (t_far < 0.0)
  {
    obj_col.t = -1.0;
    return obj_col;
  }

  // Ray inside the sphere
  if (t_near < 0.0)
  {
    obj_col.t = t_far;
    obj_col.inside = true;
  }

  obj_col.p = ray.origin + ray.dir * obj_col.t; 
  obj_col.n = normalize(obj_col.p - sphere.center);
  obj_col.mat = sphere.mat;
  obj_col.ray = ray;

  // Flip normal if ray inside
  if (obj_col.inside) obj_col.n *= -1.0;

  return obj_col;
}

// Möller-Trumbore algorithm : 
//   - express problem in barycentric coordinate P = wA + uB + vC
//   - also : P = O + tD
//   - reorganise equation of collision (unknowns should be t, u, v)
//   - solve system using Cramer's rule
Collision collision(Triangle triangle, Ray ray)
{
  vec3 edge1 = triangle.p1 - triangle.p0;
  vec3 edge2 = triangle.p2 - triangle.p0;

  Collision obj_col;
  obj_col.inside = false;

  vec3 h = cross(ray.dir, edge2);
  float a = dot(edge1, h);

  // Parallel ray and triangle
  if (a > -EPSILON && a < EPSILON)
  {
    obj_col.t = -1;
    return obj_col;
  }

  float f = 1.0 / a;

  vec3 s = ray.origin - triangle.p0;
  float u = dot(s, h) * f;
  if (u < 0.0 || u > 1.0)
  {
    obj_col.t = -1;
    return obj_col;
  }

  vec3 q = cross(s, edge1);
  float v = dot(ray.dir, q) * f;
  if (v < 0.0 || u + v > 1.0)
  {
    obj_col.t = -1;
    return obj_col;
  }

  float t = dot(edge2, q) * f;
  if (t < EPSILON)
  {
    obj_col.t = -1;
    return obj_col;
  }

  obj_col.t = t;
  obj_col.p = ray.origin + ray.dir * obj_col.t; 
  obj_col.n = normalize(cross(edge1, edge2));
  obj_col.mat = triangle.mat;
  obj_col.ray = ray;

  return obj_col;
}

Collision find_nearest(Ray ray)
{
  collisions[0] = collision(sphere, ray);
  collisions[0].object_index = 0;
  collisions[1] = collision(triangle0, ray);
  collisions[1].object_index = 1;
  collisions[2] = collision(triangle1, ray);
  collisions[2].object_index = 2;
  collisions[3] = collision(triangle2, ray);
  collisions[3].object_index = 3;
  collisions[4] = collision(sphere2, ray);
  collisions[4].object_index = 4;

  float infinity = 1.0 / 0.0;
  float min_val = infinity;
  int min_i = -1;
  for (int i = 0; i < 5; i++)
  {
    if (collisions[i].t > 0 && min_val > collisions[i].t)
    {
      min_val = collisions[i].t;
      min_i = i;
    }
  }
  min_i = (min_i == -1) ? 0 : min_i;
  return collisions[min_i];
}


// BSDF SAMPLING

Sample sample_hemisphere(vec3 n, vec2 u)
{
  vec2 r = vec2(u.x,u.y) * TWO_PI;
	vec3 dr = vec3(sin(r.x) * vec2(sin(r.y), cos(r.y)), cos(r.x));
	vec3 wi = dot(dr, n) * dr;
  
  return Sample(wi, INV_PI);
}

Sample cosine_sample_hemisphere(vec3 n, vec2 u)
{
  float theta = acos(sqrt(1.0-u.x));
  float phi = TWO_PI * u.y;

  vec3 wi = local_to_world(spherical_to_cartesian(1.0, phi, theta), n);
  float pdf = abs(dot(wi, n)) * INV_PI;  // FIXME only if same hemisphere

  return Sample(wi, pdf);
}

// This is the lambert one only for now
vec3 evaluate_bsdf(vec3 wo, vec3 wi, Collision obj_col)
{
  return obj_col.mat.diffusivity * INV_PI;
}


// LIGHT SAMPLING

vec2 uniform_sample_triangle(vec2 u)
{
  float su0 = sqrt(u.x);
  return vec2(1 - su0, u.y * su0);
}

Sample area_sample(Triangle t, vec3 origin)
{
  vec2 b = uniform_sample_triangle(vec2(rand(), rand()));
  vec3 sample_pt =  t.p0 * b.x + t.p1 * b.y + t.p2 * (1 - b.x - b.y); 

  vec3 dir = normalize(sample_pt - origin);

  // Compute area of triangle

  vec3 n = cross(t.p1 - t.p0, t.p2 - t.p0);
  float area_pdf = 2 / length(n);     // 1/area : uniform sampling over area

  return Sample(dir, area_pdf);
}

// *** NOTE *** : Multiple Importance Sampling (MIS) could be added here
vec3 uniform_sample_one_light(Collision obj_col)
{
  // TODO: pick random light
  Triangle light = triangle2;

  // Sample a ray direction from light to collision point
  Sample light_sample = area_sample(light, obj_col.p);
  vec3 wi = light_sample.value;

  Ray ray_in = Ray(obj_col.p, wi);
  ray_in.dir += obj_col.n * 1e-3 * ((dot(wi, obj_col.n) < 0) ? -1 : 1);

  Collision light_col = find_nearest(ray_in);

  // Discard if no hit or hit non emissive object 
  if (light_col.t <= 0 || light_col.mat.emission == vec3(0)) return vec3(0);

  // Evaluate the BSDF at the object's collision 
  vec3 wo = -obj_col.ray.dir;
  vec3 f = evaluate_bsdf(wo, wi, obj_col);

  // Convert area pdf to solid angle pdf
  // Intuition: adding distance / smaller angle from point to light -> smaller angle range on point hemisphere
  float pdf = light_sample.pdf * (light_col.t * light_col.t) / abs(dot(light_col.n, -wi));

  if (f == vec3(0) || pdf == 0) return vec3(0);

  return light_col.mat.emission * f * abs(dot(wi, obj_col.n)) / pdf;
}


// MAIN FUNCTIONS

vec3 pathtrace(Ray ray)
{
  vec3 L = vec3(0);                    // Total radiance estimate
  vec3 throughput = vec3(1);           // Current path throughput

  int max_bounces = 3;
  bool specular_bounce = false;

  for (int bounces = 0; ; bounces++)
  {
    // Intersect ray with scene
    Collision obj_col = find_nearest(ray);

    // Stop if no collision or no more bounce
    if (obj_col.t <= 0 || bounces >= max_bounces) break;

    // Account for the emission if :
    //  - it is the initial collision
    //  - previous was specular BSDF so no direct illumination estimate (Dirac distribution) 
    if (bounces == 0 || specular_bounce)
    {
      if (obj_col.t > 0)
      {
        L += throughput * obj_col.mat.emission;
      }
      else
      {
        // TODO: infinite area light sources
        L += vec3(0);
      }
    }

    // TODO: Compute scattering functions and skip over medium boundaries

    // Direct lighting estimation at current path vertex (end of the current path = light)
    L += throughput * uniform_sample_one_light(obj_col);

    // Sample the BSDF at intersection to get the new path direction
    Sample bsdf_sample = cosine_sample_hemisphere(obj_col.n, vec2(rand(), rand()));

    vec3 wi = bsdf_sample.value;
    vec3 wo = -ray.dir;
    vec3 f = evaluate_bsdf(wo, wi, obj_col);

    throughput *= f * abs(dot(wi, obj_col.n)) / bsdf_sample.pdf;

    ray = Ray(obj_col.p, wi);

    // Add small displacement to prevent being on the surface
    ray.dir += obj_col.n * 1e-3 * ((dot(wi, obj_col.n) < 0) ? -1 : 1);
  }

  return L;
}

void main()
{
  int width = int(gl_NumWorkGroups.x); // one workgroup = one invocation = one pixel
  int height = int(gl_NumWorkGroups.y);
  ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
  
  // Convert this pixel's screen space location to world space
  float x_pixel = 2.0 * pixel.x / width - 1.0;
  float y_pixel = 2.0 * pixel.y / height - 1.0;
  vec3 pixel_world = vec3(x_pixel, y_pixel, camera_pos_z - 1.0);
  
  // Get this pixel's world-space ray
  Ray ray;
  ray.origin = vec3(0.0, 0.0, camera_pos_z);
  ray.dir = normalize(pixel_world - ray.origin);
  
  // Cast the ray out into the world and intersect the ray with objects
  int spp = 32;
  vec3 res = vec3(0);
  for (int i = 0; i < spp; i++)
  {
    InitRNG(gl_GlobalInvocationID.xy, i);
    res += 1.0 / float(spp) * pathtrace(ray);
  } 
  imageStore(output_texture, pixel, vec4(res, 1.0));
  imageStore(debug_texture, pixel, vec4(res, 1.0));
}